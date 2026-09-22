import java.net.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Fake Kubernetes API server for Airbyte workload-launcher on Docker Swarm.
 *
 * Handles the Fabric8 client calls made by:
 *   - PodSweeper  (GET /api/v1/namespaces/default/pods?labelSelector=...)
 *   - KubePodLauncher.create  (POST /api/v1/namespaces/default/pods)
 *   - KubePodLauncher.waitFor*  (GET ...?watch=true&fieldSelector=...)
 *   - KubePodClient.deletePod  (DELETE /api/v1/namespaces/default/pods/{name})
 *   - Discovery  (GET /api, /api/v1, /apis)
 *
 * Pod creation is translated to Docker container runs via curl on the Docker
 * Unix socket (/var/run/docker.sock).  Each K8s pod maps to a Docker network
 * and a set of containers sharing a volume.
 *
 * Container lifecycle:
 *   Phase 1 – init container runs to completion (copies orchestrator jar)
 *   Phase 2 – main + connector containers run concurrently
 * We model K8s pod phases accordingly so the launcher's wait loops resolve.
 */
public class FakeK8s {

    // ── Static JSON fragments ─────────────────────────────────────────────
    static final String API_VERSIONS =
        "{\"kind\":\"APIVersions\",\"apiVersion\":\"v1\"," +
        "\"versions\":[\"v1\"],\"serverAddressByClientCIDRs\":[" +
        "{\"clientCIDR\":\"0.0.0.0/0\",\"serverAddress\":\"127.0.0.1:6443\"}]}";

    static final String API_RESOURCE_LIST =
        "{\"kind\":\"APIResourceList\",\"apiVersion\":\"v1\"," +
        "\"groupVersion\":\"v1\",\"resources\":[" +
        "{\"name\":\"pods\",\"singularName\":\"\",\"namespaced\":true," +
        "\"kind\":\"Pod\",\"verbs\":[\"create\",\"delete\",\"get\",\"list\"," +
        "\"patch\",\"update\",\"watch\"]}," +
        "{\"name\":\"namespaces\",\"singularName\":\"\",\"namespaced\":false," +
        "\"kind\":\"Namespace\",\"verbs\":[\"create\",\"get\",\"list\",\"watch\"]}," +
        "{\"name\":\"secrets\",\"singularName\":\"\",\"namespaced\":true," +
        "\"kind\":\"Secret\",\"verbs\":[\"create\",\"delete\",\"get\",\"list\"," +
        "\"patch\",\"update\",\"watch\"]}," +
        "{\"name\":\"configmaps\",\"singularName\":\"\",\"namespaced\":true," +
        "\"kind\":\"ConfigMap\",\"verbs\":[\"create\",\"delete\",\"get\",\"list\"," +
        "\"patch\",\"update\",\"watch\"]}," +
        "{\"name\":\"nodes\",\"singularName\":\"\",\"namespaced\":false," +
        "\"kind\":\"Node\",\"verbs\":[\"get\",\"list\",\"watch\"]}," +
        "{\"name\":\"resourcequotas\",\"singularName\":\"\",\"namespaced\":true," +
        "\"kind\":\"ResourceQuota\",\"verbs\":[\"get\",\"list\",\"watch\"]}]}";

    static final String API_GROUP_LIST =
        "{\"kind\":\"APIGroupList\",\"apiVersion\":\"v1\",\"groups\":[" +
        "{\"name\":\"apps\",\"versions\":[{\"groupVersion\":\"apps/v1\",\"version\":\"v1\"}]," +
        "\"preferredVersion\":{\"groupVersion\":\"apps/v1\",\"version\":\"v1\"}}]}";

    static final String APPS_API_GROUP =
        "{\"kind\":\"APIGroup\",\"apiVersion\":\"v1\",\"name\":\"apps\"," +
        "\"versions\":[{\"groupVersion\":\"apps/v1\",\"version\":\"v1\"}]," +
        "\"preferredVersion\":{\"groupVersion\":\"apps/v1\",\"version\":\"v1\"}}";

    static final String APPS_RESOURCE_LIST =
        "{\"kind\":\"APIResourceList\",\"apiVersion\":\"v1\"," +
        "\"groupVersion\":\"apps/v1\",\"resources\":[]}";

    // Label value on every container and volume FakeK8s creates, so a restarted launcher can
    // find and remove what its previous run left behind. Empty (db-migrations): no sweep.
    static final String OWNER = System.getenv().getOrDefault("FAKEK8S_OWNER", "");

    static String labelsJson(String podName) {
        return "\"Labels\":{\"airbyte.fakek8s/owner\":\"" + esc(OWNER)
            + "\",\"airbyte.fakek8s/pod\":\"" + esc(podName) + "\"}";
    }

    // ── Pod registry ──────────────────────────────────────────────────────
    // podName → PodState
    static final ConcurrentMap<String, PodState> pods = new ConcurrentHashMap<>();
    static final AtomicLong RV = new AtomicLong(1);
    // podName → list of SSE watch connections waiting for events
    static final ConcurrentMap<String, List<PrintWriter>> watchers = new ConcurrentHashMap<>();

    static class PodState {
        String name;
        String namespace = "default";
        String podJson;       // full pod JSON as created
        String phase;         // Pending, Running, Succeeded, Failed
        String initPhase;     // Waiting, Running, Terminated
        boolean initDone;
        boolean mainRunning;
        String creationTimestamp;
        String startTime;
        String completionTime;
        Map<String,String> labels = new HashMap<>();
        volatile String resourceVersion = "1";
        volatile int initExitCode = 0;

        PodState(String name, String podJson) {
            this.name = name;
            this.podJson = podJson;
            this.phase = "Pending";
            this.initPhase = "Waiting";
            this.initDone = false;
            this.mainRunning = false;
            this.creationTimestamp = iso8601Now();
            this.startTime = this.creationTimestamp;
            this.completionTime = null;
        }
    }

    // ── Utilities ─────────────────────────────────────────────────────────
    static String iso8601Now() {
        return java.time.Instant.now().toString().replaceAll("\\.\\d+Z$","Z");
    }

    // Short timestamp for log lines: HH:mm:ss.SSS
    static String ts() {
        return java.time.LocalTime.now()
            .format(java.time.format.DateTimeFormatter.ofPattern("HH:mm:ss.SSS"));
    }

    static void log(String msg) {
        System.out.println("[FakeK8s " + ts() + "] " + msg);
    }

    static void err(String msg) {
        System.err.println("[FakeK8s " + ts() + "] ERROR: " + msg);
    }

    static String esc(String s) {
        if (s == null) return "";
        return s.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","\\r").replace("\t","\\t");
    }

    static String podToJson(PodState p) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"apiVersion\":\"v1\",\"kind\":\"Pod\",");
        sb.append("\"metadata\":{\"name\":\"").append(esc(p.name)).append("\",");
        sb.append("\"namespace\":\"").append(esc(p.namespace)).append("\",");
        sb.append("\"creationTimestamp\":\"").append(esc(p.creationTimestamp)).append("\",");
        sb.append("\"labels\":{");
        boolean first = true;
        for (var e : p.labels.entrySet()) {
            if (!first) sb.append(",");
            sb.append("\"").append(esc(e.getKey())).append("\":\"").append(esc(e.getValue())).append("\"");
            first = false;
        }
        sb.append("},\"resourceVersion\":\"").append(p.resourceVersion).append("\",\"uid\":\"").append(p.name).append("-uid\"},");
        sb.append("\"spec\":{\"containers\":[]},");
        sb.append("\"status\":{\"phase\":\"").append(esc(p.phase)).append("\",");
        sb.append("\"startTime\":\"").append(esc(p.startTime)).append("\",");
        // init container statuses
        if (!p.initDone) {
            if ("Failed".equals(p.phase)) {
                sb.append("\"initContainerStatuses\":[{\"name\":\"init\",\"ready\":false,");
                sb.append("\"state\":{\"terminated\":{\"exitCode\":").append(p.initExitCode).append(",\"reason\":\"Error\",");
                sb.append("\"finishedAt\":\"").append(esc(p.completionTime != null ? p.completionTime : iso8601Now())).append("\"}}}],");
            } else if ("Running".equals(p.initPhase)) {
                sb.append("\"initContainerStatuses\":[{\"name\":\"init\",\"ready\":false,");
                sb.append("\"state\":{\"running\":{\"startedAt\":\"").append(esc(p.creationTimestamp)).append("\"}}}],");
            } else {
                sb.append("\"initContainerStatuses\":[{\"name\":\"init\",\"ready\":false,");
                sb.append("\"state\":{\"waiting\":{\"reason\":\"PodInitializing\"}}}],");
            }
        } else {
            sb.append("\"initContainerStatuses\":[{\"name\":\"init\",\"ready\":true,");
            sb.append("\"state\":{\"terminated\":{\"exitCode\":0,\"reason\":\"Completed\",");
            sb.append("\"finishedAt\":\"").append(esc(p.creationTimestamp)).append("\"}}}],");
        }
        // main container status
        if ("Succeeded".equals(p.phase) || "Failed".equals(p.phase)) {
            int code = "Failed".equals(p.phase) ? 1 : 0;
            sb.append("\"containerStatuses\":[{\"name\":\"main\",\"ready\":false,");
            sb.append("\"state\":{\"terminated\":{\"exitCode\":").append(code).append(",");
            sb.append("\"reason\":\"").append("Failed".equals(p.phase)?"Error":"Completed").append("\",");
            sb.append("\"finishedAt\":\"").append(esc(p.completionTime != null ? p.completionTime : iso8601Now())).append("\"}}}]");
        } else if (p.mainRunning) {
            sb.append("\"containerStatuses\":[{\"name\":\"main\",\"ready\":true,");
            sb.append("\"state\":{\"running\":{\"startedAt\":\"").append(esc(p.startTime)).append("\"}}}]");
        } else {
            sb.append("\"containerStatuses\":[{\"name\":\"main\",\"ready\":false,");
            sb.append("\"state\":{\"waiting\":{\"reason\":\"PodInitializing\"}}}]");
        }

        sb.append(",\"conditions\":[");
        if ("Succeeded".equals(p.phase) || "Failed".equals(p.phase)) {
            String doneAt = esc(p.completionTime != null ? p.completionTime : iso8601Now());
            sb.append("{\"type\":\"PodScheduled\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"Initialized\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"ContainersReady\",\"status\":\"False\",\"lastTransitionTime\":\"").append(doneAt).append("\"},");
            sb.append("{\"type\":\"Ready\",\"status\":\"False\",\"lastTransitionTime\":\"").append(doneAt).append("\"}");
        } else if (p.mainRunning) {
            sb.append("{\"type\":\"PodScheduled\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"Initialized\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"ContainersReady\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"Ready\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"}");
        } else {
            sb.append("{\"type\":\"PodScheduled\",\"status\":\"True\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"Initialized\",\"status\":\"False\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"ContainersReady\",\"status\":\"False\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"},");
            sb.append("{\"type\":\"Ready\",\"status\":\"False\",\"lastTransitionTime\":\"").append(esc(p.startTime)).append("\"}");
        }
        sb.append("]");
        sb.append("}}");
        return sb.toString();
    }

    static String podListJson(Collection<PodState> list) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"apiVersion\":\"v1\",\"kind\":\"PodList\",");
        sb.append("\"metadata\":{\"resourceVersion\":\"").append(RV.get()).append("\"},\"items\":[");
        boolean first = true;
        for (PodState p : list) {
            if (!first) sb.append(",");
            sb.append(podToJson(p));
            first = false;
        }
        sb.append("]}");
        return sb.toString();
    }

    static Collection<PodState> podsMatchingLabelSelector(String query) {
        String selector = "";
        for (String part : query.split("&")) {
            if (part.startsWith("labelSelector=")) {
                try {
                    selector = URLDecoder.decode(part.substring("labelSelector=".length()), "UTF-8");
                } catch (Exception ignored) {}
                break;
            }
        }
        for (String part : query.split("&")) {
            if (!part.startsWith("fieldSelector=")) continue;
            try {
                String fields = URLDecoder.decode(part.substring("fieldSelector=".length()), "UTF-8");
                for (String field : fields.split(",")) {
                    if (field.startsWith("metadata.name=")) {
                        PodState only = pods.get(field.substring("metadata.name=".length()));
                        return only == null ? List.of() : List.of(only);
                    }
                }
            } catch (Exception ignored) {}
        }
        if (selector.isEmpty()) return pods.values();

        List<PodState> matched = new ArrayList<>();
        for (PodState pod : pods.values()) {
            boolean matches = true;
            for (String requirement : selector.split(",")) {
                int equals = requirement.indexOf('=');
                if (equals <= 0 || !pod.labels.containsKey(requirement.substring(0, equals)) ||
                    !pod.labels.get(requirement.substring(0, equals)).equals(requirement.substring(equals + 1))) {
                    matches = false;
                    break;
                }
            }
            if (matches) matched.add(pod);
        }
        return matched;
    }

    static String watchEvent(String type, PodState p) {
        return "{\"type\":\"" + type + "\",\"object\":" + podToJson(p) + "}";
    }

    // ── Docker socket helpers ─────────────────────────────────────────────
    static String dockerGet(String path) throws Exception {
        Process proc = new ProcessBuilder(
            "curl", "-sf", "--unix-socket", "/var/run/docker.sock",
            "http://localhost" + path
        ).redirectErrorStream(true).start();
        String out = new String(proc.getInputStream().readAllBytes());
        proc.waitFor(10, TimeUnit.SECONDS);
        return out;
    }

    static String dockerPost(String path, String body) throws Exception {
        Process proc = new ProcessBuilder(
            "curl", "-s", "--unix-socket", "/var/run/docker.sock",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", body,
            "http://localhost" + path
        ).redirectErrorStream(true).start();
        String out = new String(proc.getInputStream().readAllBytes());
        proc.waitFor(30, TimeUnit.SECONDS);
        return out;
    }

    static void dockerDelete(String path) throws Exception {
        new ProcessBuilder(
            "curl", "-sf", "--unix-socket", "/var/run/docker.sock",
            "-X", "DELETE",
            "http://localhost" + path
        ).redirectErrorStream(true).start().waitFor(10, TimeUnit.SECONDS);
    }

    // Simple JSON string extraction: get value of "key" from flat JSON
    static String jsonStr(String json, String key) {
        String search = "\"" + key + "\":\"";
        int i = json.indexOf(search);
        if (i < 0) return "";
        i += search.length();
        StringBuilder sb = new StringBuilder();
        while (i < json.length()) {
            char c = json.charAt(i);
            if (c == '\\' && i + 1 < json.length()) {
                char next = json.charAt(i + 1);
                switch (next) {
                    case '"':  sb.append('"');  break;
                    case '\\': sb.append('\\'); break;
                    case 'n':  sb.append('\n'); break;
                    case 'r':  sb.append('\r'); break;
                    case 't':  sb.append('\t'); break;
                    default:   sb.append(next); break;
                }
                i += 2;
                continue;
            }
            if (c == '"') break;
            sb.append(c);
            i++;
        }
        return sb.toString();
    }

    // Like jsonStr but only matches at top level of the JSON object (depth==1),
    // ignoring nested arrays/objects (e.g. env var "name" fields inside "env":[...]).
    static String jsonStrTopLevel(String json, String key) {
        String search = "\"" + key + "\":\"";
        int depth = 0;
        for (int i = 0; i < json.length() - search.length(); i++) {
            char c = json.charAt(i);
            if (c == '{' || c == '[') { depth++; continue; }
            if (c == '}' || c == ']') { depth--; continue; }
            if (depth == 1 && json.startsWith(search, i)) {
                int start = i + search.length();
                int end = json.indexOf('"', start);
                return end < 0 ? "" : json.substring(start, end);
            }
        }
        return "";
    }

    // Extract array of container specs (name + image) from pod JSON
    static List<Map<String,String>> extractContainers(String podJson, String arrayKey) {
        List<Map<String,String>> result = new ArrayList<>();
        int start = podJson.indexOf("\"" + arrayKey + "\":[");
        if (start < 0) return result;
        start = podJson.indexOf('[', start);
        // Walk through objects in the array
        int depth = 0;
        int objStart = -1;
        for (int i = start; i < podJson.length(); i++) {
            char c = podJson.charAt(i);
            if (c == '{') { depth++; if (depth == 1) objStart = i; }
            else if (c == '}') {
                depth--;
                if (depth == 0 && objStart >= 0) {
                    String obj = podJson.substring(objStart, i + 1);
                    Map<String,String> m = new HashMap<>();
                    m.put("name", jsonStrTopLevel(obj, "name"));
                    m.put("image", jsonStrTopLevel(obj, "image"));
                    // Extract env vars: "env":[{"name":"K","value":"V"},...]
                    m.put("envJson", extractEnvJson(obj));
                    // Extract volume mounts
                    m.put("volumeMountsJson", extractVolumeMounts(obj));
                    // Extract args (K8s args → Docker Cmd) and command (K8s command → Docker Entrypoint)
                    m.put("argsJson", extractArgsJson(obj));
                    m.put("commandJson", extractCommandJson(obj));
                    result.add(m);
                    objStart = -1;
                }
            } else if (c == ']' && depth == 0) break;
        }
        return result;
    }

    static String extractEnvJson(String containerJson) {
        int i = containerJson.indexOf("\"env\":[");
        if (i < 0) return "[]";
        int start = containerJson.indexOf('[', i);
        int depth = 0, end = start;
        for (; end < containerJson.length(); end++) {
            char c = containerJson.charAt(end);
            if (c == '[') depth++;
            else if (c == ']') { depth--; if (depth == 0) break; }
        }
        return containerJson.substring(start, end + 1);
    }

    static String extractVolumeMounts(String containerJson) {
        int i = containerJson.indexOf("\"volumeMounts\":[");
        if (i < 0) return "[]";
        int start = containerJson.indexOf('[', i);
        int depth = 0, end = start;
        for (; end < containerJson.length(); end++) {
            char c = containerJson.charAt(end);
            if (c == '[') depth++;
            else if (c == ']') { depth--; if (depth == 0) break; }
        }
        return containerJson.substring(start, end + 1);
    }

    static String extractArgsJson(String containerJson) {
        int i = containerJson.indexOf("\"args\":[");
        if (i < 0) i = containerJson.indexOf("\"args\" :[");
        if (i < 0) i = containerJson.indexOf("\"args\": [");
        if (i < 0) return "[]";
        int start = containerJson.indexOf('[', i);
        int depth = 0, end = start;
        for (; end < containerJson.length(); end++) {
            char c = containerJson.charAt(end);
            if (c == '[') depth++;
            else if (c == ']') { depth--; if (depth == 0) break; }
        }
        return containerJson.substring(start, end + 1);
    }

    static String extractCommandJson(String containerJson) {
        int i = containerJson.indexOf("\"command\":[");
        if (i < 0) i = containerJson.indexOf("\"command\" :[");
        if (i < 0) i = containerJson.indexOf("\"command\": [");
        if (i < 0) return "[]";
        int start = containerJson.indexOf('[', i);
        int depth = 0, end = start;
        for (; end < containerJson.length(); end++) {
            char c = containerJson.charAt(end);
            if (c == '[') depth++;
            else if (c == ']') { depth--; if (depth == 0) break; }
        }
        return containerJson.substring(start, end + 1);
    }

    static List<String> jsonArrayToStringList(String json) {
        List<String> result = new ArrayList<>();
        if (json == null || json.isEmpty()) return result;
        int i = 0;
        while (true) {
            int qs = json.indexOf('"', i);
            if (qs < 0) break;
            qs++;
            StringBuilder sb = new StringBuilder();
            int qe = qs;
            while (qe < json.length()) {
                char c = json.charAt(qe);
                if (c == '\\' && qe + 1 < json.length()) {
                    char next = json.charAt(qe + 1);
                    switch (next) {
                        case '"':  sb.append('"');  break;
                        case '\\': sb.append('\\'); break;
                        case 'n':  sb.append('\n'); break;
                        case 'r':  sb.append('\r'); break;
                        case 't':  sb.append('\t'); break;
                        default:   sb.append(next); break;
                    }
                    qe += 2;
                    continue;
                }
                if (c == '"') break;
                sb.append(c);
                qe++;
            }
            result.add(sb.toString());
            i = qe + 1;
        }
        return result;
    }

    static List<String> forceMicronautRandomPort(List<String> args) {
        List<String> sanitized = new ArrayList<>();
        boolean skipNext = false;
        for (String a : args) {
            if (skipNext) {
                skipNext = false;
                continue;
            }
            if (a.equals("--micronaut.server.port")) {
                skipNext = true;
                continue;
            }
            if (a.startsWith("--micronaut.server.port=")) {
                continue;
            }
            sanitized.add(a);
        }
        sanitized.add("--micronaut.server.port=0");
        return sanitized;
    }

    static List<String> forceOrchestratorPortInCommand(List<String> command) {
        if (command == null || command.isEmpty()) return command;

        List<String> rewritten = new ArrayList<>(command);

        if (rewritten.size() >= 3 && "sh".equals(rewritten.get(0)) && "-c".equals(rewritten.get(1))) {
            String script = rewritten.get(2);
            if (script.contains("airbyte-container-orchestrator")) {
                script = script.replace(
                    "/app/airbyte-app/bin/airbyte-container-orchestrator",
                    "/app/airbyte-app/bin/airbyte-container-orchestrator --micronaut.server.port=0"
                );
                script = script.replace(
                    " airbyte-container-orchestrator",
                    " airbyte-container-orchestrator --micronaut.server.port=0"
                );
                rewritten.set(2, script);
            }
            return rewritten;
        }

        if (!rewritten.isEmpty() && rewritten.get(0).contains("airbyte-container-orchestrator")) {
            boolean hasPortArg = false;
            for (String arg : rewritten) {
                if ("--micronaut.server.port".equals(arg) || arg.startsWith("--micronaut.server.port=")) {
                    hasPortArg = true;
                    break;
                }
            }
            if (!hasPortArg) rewritten.add("--micronaut.server.port=0");
        }

        return rewritten;
    }

    // Convert K8s env array to Docker envs list: ["KEY=VALUE",...]
    static List<String> envJsonToDockerEnv(String envJson) {
        List<String> result = new ArrayList<>();
        // Parse [{"name":"K","value":"V"},{"name":"K2","valueFrom":{...}},...]
        int i = 0;
        while (true) {
            int ob = envJson.indexOf('{', i);
            if (ob < 0) break;
            int depth = 0, eb = ob;
            for (; eb < envJson.length(); eb++) {
                char c = envJson.charAt(eb);
                if (c == '{') depth++;
                else if (c == '}') { depth--; if (depth == 0) break; }
            }
            String obj = envJson.substring(ob, eb + 1);
            String name = jsonStr(obj, "name");
            String value = jsonStr(obj, "value");
            // For valueFrom env vars (secretKeyRef, configMapKeyRef, fieldRef),
            // the value field is absent. Fall back to the launcher's own environment
            // because the launcher has the real values (DATAPLANE_CLIENT_ID, etc.)
            // and the fake K8s secret always returns empty data.
            if (!name.isEmpty() && value.isEmpty() && obj.contains("valueFrom")) {
                String inherited = System.getenv(name);
                if (inherited != null) {
                    value = inherited;
                    log("  [env] inherited valueFrom env: " + name + "=(" + inherited.length() + " chars)");
                }
            }
            if (!name.isEmpty()) result.add(name + "=" + value);
            i = eb + 1;
        }
        return result;
    }

    // Parse K8s volume mounts → find mountPath for a given volume name
    static String findMountPath(String volumeMountsJson, String volumeName) {
        int i = 0;
        while (true) {
            int ob = volumeMountsJson.indexOf('{', i);
            if (ob < 0) break;
            int depth = 0, eb = ob;
            for (; eb < volumeMountsJson.length(); eb++) {
                char c = volumeMountsJson.charAt(eb);
                if (c == '{') depth++;
                else if (c == '}') { depth--; if (depth == 0) break; }
            }
            String obj = volumeMountsJson.substring(ob, eb + 1);
            if (volumeName.equals(jsonStr(obj, "name"))) {
                return jsonStr(obj, "mountPath");
            }
            i = eb + 1;
        }
        return null;
    }

    // Extract K8s volume definitions from pod spec: volumes[{name, configMap|secret|emptyDir...}]
    static Map<String,String> extractVolumeTypes(String podJson) {
        Map<String,String> result = new HashMap<>(); // name → type hint
        int vi = podJson.indexOf("\"volumes\":[");
        if (vi < 0) return result;
        int start = podJson.indexOf('[', vi);
        int depth = 0, i = start;
        int objStart = -1;
        for (; i < podJson.length(); i++) {
            char c = podJson.charAt(i);
            if (c == '{') { depth++; if (depth == 1) objStart = i; }
            else if (c == '}') {
                depth--;
                if (depth == 0 && objStart >= 0) {
                    String obj = podJson.substring(objStart, i + 1);
                    String name = jsonStr(obj, "name");
                    String type = obj.contains("\"emptyDir\"") ? "emptyDir"
                        : obj.contains("\"configMap\"") ? "configMap"
                        : obj.contains("\"secret\"") ? "secret"
                        : obj.contains("\"hostPath\"") ? "hostPath"
                        : "unknown";
                    if (!name.isEmpty()) result.put(name, type);
                    objStart = -1;
                }
            } else if (c == ']' && depth == 0) break;
        }
        return result;
    }

    // Extract labels from pod metadata
    static Map<String,String> extractLabels(String podJson) {
        Map<String,String> result = new HashMap<>();
        int mi = podJson.indexOf("\"metadata\":{");
        if (mi < 0) return result;
        int li = podJson.indexOf("\"labels\":{", mi);
        if (li < 0) return result;
        int start = podJson.indexOf('{', li + 8);
        int depth = 0, i = start;
        StringBuilder key = null;
        // Simple k/v parser (only one level deep)
        String sub = podJson.substring(start);
        // Just parse "key":"value" pairs until closing }
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("\"([^\"]+)\":\"([^\"]*)\"").matcher(sub);
        int limit = sub.indexOf('}');
        while (m.find() && m.start() < limit) {
            result.put(m.group(1), m.group(2));
        }
        return result;
    }

    static String extractPodName(String podJson) {
        // Extract metadata.name at depth 0 of the metadata object only,
        // to avoid matching "name" fields inside nested objects (managedFields, etc.)
        int mi = podJson.indexOf("\"metadata\":{");
        if (mi < 0) return "pod-" + System.currentTimeMillis();
        int metaStart = podJson.indexOf('{', mi + 10);
        if (metaStart < 0) return "pod-" + System.currentTimeMillis();
        int depth = 0, metaEnd = metaStart + 1;
        for (int i = metaStart; i < podJson.length(); i++) {
            char c = podJson.charAt(i);
            if (c == '{') depth++;
            else if (c == '}') { depth--; if (depth == 0) { metaEnd = i + 1; break; } }
        }
        String name = jsonStrTopLevel(podJson.substring(metaStart, metaEnd), "name");
        return name.isEmpty() ? "pod-" + System.currentTimeMillis() : name;
    }

    // ── Docker container management ───────────────────────────────────────
    // Run a Docker container for a K8s container spec.
    // Returns container ID or "" on failure.
    static String runDockerContainer(
        String podName, String containerName, String image,
        List<String> envVars,
        List<String> volumeBinds,  // "srcPath:destPath"
        String networkName,
        List<String> extraNetworks,
        boolean detach,
        List<String> cmdArgs,
        List<String> entrypoint,
        String workingDir
    ) {
        StringBuilder body = new StringBuilder();
        body.append("{\"Image\":\"").append(esc(image)).append("\",");
        body.append(labelsJson(podName)).append(",");
        if (workingDir != null && !workingDir.isEmpty()) {
            body.append("\"WorkingDir\":\"").append(esc(workingDir)).append("\",");
        }
        if (entrypoint != null && !entrypoint.isEmpty()) {
            body.append("\"Entrypoint\":[");
            for (int i = 0; i < entrypoint.size(); i++) {
                if (i > 0) body.append(",");
                body.append("\"").append(esc(entrypoint.get(i))).append("\"");
            }
            body.append("],");
        }
        if (cmdArgs != null && !cmdArgs.isEmpty()) {
            body.append("\"Cmd\":[");
            for (int i = 0; i < cmdArgs.size(); i++) {
                if (i > 0) body.append(",");
                body.append("\"").append(esc(cmdArgs.get(i))).append("\"");
            }
            body.append("],");
        }
        body.append("\"Env\":[");
        for (int i = 0; i < envVars.size(); i++) {
            if (i > 0) body.append(",");
            body.append("\"").append(esc(envVars.get(i))).append("\"");
        }
        body.append("],");
        body.append("\"HostConfig\":{");
        body.append("\"Binds\":[");
        for (int i = 0; i < volumeBinds.size(); i++) {
            if (i > 0) body.append(",");
            body.append("\"").append(esc(volumeBinds.get(i))).append("\"");
        }
        body.append("],");
        if (networkName != null) {
            body.append("\"NetworkMode\":\"").append(esc(networkName)).append("\",");
        }
        body.append("\"AutoRemove\":false},");
        // For container: network mode, EndpointsConfig causes errors — skip it
        boolean isContainerNet = networkName != null && networkName.startsWith("container:");
        body.append("\"NetworkingConfig\":{\"EndpointsConfig\":{");
        if (networkName != null && !isContainerNet) {
            body.append("\"").append(esc(networkName)).append("\":{}");
        }
        body.append("}}}");

        String cname = (podName + "-" + containerName).replaceAll("[^a-zA-Z0-9_.-]", "_");
        try {
            // Create container
            String resp = dockerPost("/v1.41/containers/create?name=" + cname, body.toString());
            String id = jsonStr(resp, "Id");
            if (id.isEmpty()) {
                err("Failed to create container " + cname
                    + "\n  docker response: " + resp);
                return "";
            }

            // Attach to additional networks if requested (e.g. shared-services for DB DNS).
            if (extraNetworks != null) {
                for (String net : extraNetworks) {
                    if (net == null || net.isEmpty()) continue;
                    if (networkName != null && networkName.equals(net)) continue;
                    try {
                        String connectBody = "{\"Container\":\"" + esc(id) + "\"}";
                        String connectResp = dockerPost("/v1.41/networks/" + net + "/connect", connectBody);
                        if (connectResp != null && !connectResp.isEmpty() && connectResp.contains("\"message\"")) {
                            err("Container " + cname + " network connect error (" + net + "): " + connectResp);
                        } else {
                            log("  [docker] connected " + cname + " to network " + net);
                        }
                    } catch (Exception e) {
                        err("Container " + cname + " failed to connect network " + net + ": " + e);
                    }
                }
            }

            // Start container
            String startResp = dockerPost("/v1.41/containers/" + id + "/start", "{}");
            if (startResp != null && !startResp.isEmpty() && startResp.contains("\"message\"")) {
                err("Container " + cname + " start error: " + startResp);
            }
            log("  [docker] created+started " + cname + "  id=" + id.substring(0, Math.min(12, id.length())));
            return id;
        } catch (Exception e) {
            err("Error running container " + cname + ": " + e);
            return "";
        }
    }

    // Wait for a container to finish and return its exit code
    static int waitContainer(String containerId) {
        try {
            String resp = dockerPost("/v1.41/containers/" + containerId + "/wait", "{}");
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("\\\"StatusCode\\\"\\s*:\\s*(\\d+)").matcher(resp);
            if (!m.find()) {
                err("  [wait] container " + containerId.substring(0, Math.min(12, containerId.length()))
                    + " returned no exit code: " + resp);
                return 1;
            }
            int parsedCode = Integer.parseInt(m.group(1));
            if (resp.contains("\"Error\"") && !resp.contains("\"Error\":null")) {
                err("  [wait] container " + containerId.substring(0, Math.min(12, containerId.length()))
                    + " wait response had error: " + resp);
            }
            return parsedCode;
        } catch (Exception e) {
            err("  [wait] exception for " + containerId.substring(0, Math.min(12, containerId.length())) + ": " + e);
            return 1;
        }
    }

    static void removeContainer(String containerId) {
        try { dockerDelete("/v1.41/containers/" + containerId + "?force=true"); }
        catch (Exception ignored) {}
    }

    static void dumpContainerLogs(String containerId, String label) {
        try {
            Process proc = new ProcessBuilder(
                "curl", "-s", "--unix-socket", "/var/run/docker.sock",
                "http://localhost/v1.41/containers/" + containerId + "/logs?stdout=1&stderr=1&tail=100"
            ).redirectErrorStream(true).start();
            byte[] raw = proc.getInputStream().readAllBytes();
            proc.waitFor(10, TimeUnit.SECONDS);
            // Docker log stream has 8-byte headers per frame — strip them
            StringBuilder sb = new StringBuilder();
            int i = 0;
            while (i + 8 <= raw.length) {
                int size = ((raw[i+4] & 0xFF) << 24) | ((raw[i+5] & 0xFF) << 16)
                         | ((raw[i+6] & 0xFF) << 8)  |  (raw[i+7] & 0xFF);
                int end = Math.min(i + 8 + size, raw.length);
                sb.append(new String(raw, i + 8, end - (i + 8)));
                i = end;
            }
            String logs = sb.toString().trim();
            if (!logs.isEmpty()) {
                System.out.println("[FakeK8s] === " + label + " logs ===");
                for (String line : logs.split("\n")) System.out.println("[FakeK8s] " + label + ": " + line.trim());
                System.out.println("[FakeK8s] === end " + label + " ===");
            }
        } catch (Exception e) {
            System.err.println("[FakeK8s] dumpLogs failed for " + label + ": " + e);
        }
    }

    // Pull image if not present (best effort)
    static void pullImage(String image) {
        try {
            // Check if image already exists locally before pulling
            String imgName = image.contains(":") ? image.substring(0, image.lastIndexOf(':')) : image;
            String imgTag  = image.contains(":") ? image.substring(image.lastIndexOf(':') + 1) : "latest";
            String checkResp = dockerGet("/v1.41/images/" + imgName + ":" + imgTag + "/json");
            if (!checkResp.contains("\"error\"") && checkResp.contains("\"Id\"")) {
                log("  [pull] image already present locally: " + image);
                return;
            }
            String url = "http://localhost/v1.41/images/create?fromImage=" + imgName + "&tag=" + imgTag;
            long t0 = System.currentTimeMillis();
            log("  [pull] PULLING " + image + "...");
            Process proc = new ProcessBuilder(
                "curl", "-s", "--unix-socket", "/var/run/docker.sock",
                "-X", "POST", url
            ).redirectErrorStream(true).start();
            // Must consume stdout or the pipe buffer fills and curl blocks
            String pullOutput = new String(proc.getInputStream().readAllBytes());
            boolean done = proc.waitFor(300, TimeUnit.SECONDS);
            long elapsed = System.currentTimeMillis() - t0;
            if (!done) {
                proc.destroyForcibly();
                err("  [pull] TIMED OUT for " + image + " after " + elapsed + "ms");
            } else if (pullOutput.contains("\"error\"")) {
                err("  [pull] FAILED for " + image + " (" + elapsed + "ms): "
                    + pullOutput.substring(0, Math.min(300, pullOutput.length())));
            } else {
                log("  [pull] OK " + image + " (" + elapsed + "ms)");
            }
        } catch (Exception e) {
            err("  [pull] exception for " + image + ": " + e);
        }
    }

    // ── Pod execution ─────────────────────────────────────────────────────
    static final ExecutorService exec = Executors.newCachedThreadPool();

    // Discover the launcher's primary Docker network so pod sandboxes can
    // join the same overlay and still reach Airbyte services by DNS name.
    static String launcherPrimaryNetworkName() {
        String launcherHostname = System.getenv("HOSTNAME");
        if (launcherHostname == null || launcherHostname.isEmpty()) return null;
        try {
            String resp = dockerGet("/v1.41/containers/" + launcherHostname + "/json");
            java.util.regex.Matcher networkBlock = java.util.regex.Pattern
                .compile("\\\"Networks\\\"\\s*:\\s*\\{")
                .matcher(resp);
            if (!networkBlock.find()) return null;

            int start = resp.indexOf('{', networkBlock.start());
            if (start < 0) return null;
            int depth = 0;
            int end = -1;
            for (int i = start; i < resp.length(); i++) {
                char c = resp.charAt(i);
                if (c == '{') depth++;
                else if (c == '}') {
                    depth--;
                    if (depth == 0) { end = i + 1; break; }
                }
            }
            if (end < 0) return null;

            String networksObj = resp.substring(start, end);
            java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("\"([^\"]+)\"\\s*:\\s*\\{")
                .matcher(networksObj);
            List<String> names = new ArrayList<>();
            while (m.find()) names.add(m.group(1));
            if (names.isEmpty()) return null;

            // Prefer dedicated v2 network first when present.
            for (String n : names) if (n.endsWith("_airbyte-v2")) return n;
            for (String n : names) if (n.endsWith("-v2")) return n;
            for (String n : names) if (n.endsWith("_default")) return n;
            return names.get(0);
        } catch (Exception e) {
            err("Failed to detect launcher network: " + e);
            return null;
        }
    }

    static String configuredPodNetworkName() {
        String explicit = System.getenv("FAKEK8S_POD_NETWORK");
        if (explicit == null) return null;
        explicit = explicit.trim();
        return explicit.isEmpty() ? null : explicit;
    }

    static List<String> configuredPodExtraNetworks() {
        String raw = System.getenv("FAKEK8S_POD_EXTRA_NETWORKS");
        List<String> result = new ArrayList<>();
        if (raw == null || raw.trim().isEmpty()) return result;
        for (String token : raw.split(",")) {
            String network = token.trim();
            if (!network.isEmpty()) result.add(network);
        }
        return result;
    }

    static void launchPod(String podJson) {
        launchPod(podJson, null);
    }

    // nameOverride: when non-null, use this as the pod name instead of extracting
    // from the body. The PATCH (server-side apply) handler passes the URL-path name
    // here to avoid extractPodName picking up a wrong nested "name" field.
    static void launchPod(String podJson, String nameOverride) {
        String podName = (nameOverride != null && !nameOverride.isEmpty())
            ? nameOverride : extractPodName(podJson);
        Map<String,String> labels = extractLabels(podJson);

        PodState pod = new PodState(podName, podJson);
        pod.labels = labels;
        pods.put(podName, pod);
        notifyWatchers(podName, "ADDED", pod);
        log("POD REGISTERED: " + podName + " (total tracked: " + pods.size() + ")");

        exec.submit(() -> {
            try {
                runPodLifecycle(podName, podJson, pod);
            } catch (Exception e) {
                err("Pod " + podName + " unhandled exception: " + e);
                e.printStackTrace();
                pod.phase = "Failed";
                notifyWatchers(podName, "MODIFIED", pod);
            }
        });
    }

    static void runPodLifecycle(String podName, String podJson, PodState pod) throws Exception {
        Map<String,String> volumeTypes = extractVolumeTypes(podJson);
        List<Map<String,String>> initContainers = extractContainers(podJson, "initContainers");
        List<Map<String,String>> mainContainers = extractContainers(podJson, "containers");

        log("POD LIFECYCLE START: " + podName
            + " | init-containers=" + initContainers.size()
            + " main-containers=" + mainContainers.size());
        for (var c : initContainers) log("  [init] " + c.get("name") + "  image=" + c.get("image"));
        for (var c : mainContainers) log("  [main] " + c.get("name") + "  image=" + c.get("image"));

        // Create one Docker volume per K8s emptyDir volume name.
        // Using a single shared volume caused all mount paths (e.g. /source, /dest, /config)
        // to share the same filesystem root, making init-written files overwrite each other.
        // Pre-pull helper image used for chmod so first-run permissions setup does not fail.
        pullImage("busybox:1.37.0");
        String podSafe = podName.replaceAll("[^a-zA-Z0-9_.-]", "_");
        Map<String, String> emptyDirVolumes = new HashMap<>(); // k8s vol name → docker vol name
        for (String volName : volumeTypes.keySet()) {
            if (!"emptyDir".equals(volumeTypes.get(volName))) continue;
            String dockerVol = "airbyte-emptydir-" + podSafe + "-" + volName.replaceAll("[^a-zA-Z0-9_.-]", "_");
            emptyDirVolumes.put(volName, dockerVol);
            try {
                dockerPost("/v1.41/volumes/create", "{\"Name\":\"" + esc(dockerVol) + "\"," + labelsJson(podName) + "}");
                log("  emptyDir volume=" + dockerVol + " created (k8s=" + volName + ")");
            } catch (Exception e) {
                err("  emptyDir volume create failed: " + e);
            }
            // Make world-writable so non-root containers can write to it.
            try {
                String chmodId = runDockerContainer(podName, "emptydir-chmod-" + volName.replaceAll("[^a-zA-Z0-9]", "-"),
                    "busybox:1.37.0", Collections.emptyList(),
                    List.of(dockerVol + ":/mnt"), null, Collections.emptyList(), false,
                    Collections.emptyList(), List.of("chmod", "777", "/mnt"), null);
                if (!chmodId.isEmpty()) {
                    waitContainer(chmodId);
                    removeContainer(chmodId);
                }
            } catch (Exception e) {
                err("  emptyDir volume chmod failed: " + e);
            }
        }
        log("  emptyDir volumes: " + emptyDirVolumes);

        // Build volume binds helper
        java.util.function.Function<Map<String,String>, List<String>> buildBinds = (container) -> {
            List<String> binds = new ArrayList<>();
            String mountsJson = container.get("volumeMountsJson");
            if (mountsJson != null) {
                for (String volName : volumeTypes.keySet()) {
                    String type = volumeTypes.get(volName);
                    String mountPath = findMountPath(mountsJson, volName);
                    if (mountPath == null || mountPath.isEmpty()) continue;
                    if ("emptyDir".equals(type)) {
                        String dockerVol = emptyDirVolumes.get(volName);
                        if (dockerVol != null) binds.add(dockerVol + ":" + mountPath);
                    }
                }
            }
            return binds;
        };

        // Prefer placing each pod on the launcher's overlay network (isolated netns
        // per pod, avoids cross-pod localhost port collisions such as orchestrator:8085).
        // Fallback to container:<launcher> if network detection fails.
        String explicitNetwork = configuredPodNetworkName();
        List<String> extraNetworks = configuredPodExtraNetworks();
        String launcherNetwork = launcherPrimaryNetworkName();
        String launcherHostname = System.getenv("HOSTNAME");
        String podNetworkMode = (explicitNetwork != null && !explicitNetwork.isEmpty())
            ? explicitNetwork
            : ((launcherNetwork != null && !launcherNetwork.isEmpty())
            ? launcherNetwork
            : ((launcherHostname != null && !launcherHostname.isEmpty()) ? "container:" + launcherHostname : null));
        log("  pod network mode: " + podNetworkMode
            + "  (explicit=" + explicitNetwork + ", launcher network=" + launcherNetwork + ", launcher HOSTNAME=" + launcherHostname + ")");
        if (!extraNetworks.isEmpty()) {
            log("  pod extra networks: " + extraNetworks);
        }

        // ── Phase 1: Run init containers sequentially ─────────────────────
        log("POD " + podName + " → PHASE 1: init containers");
        for (Map<String,String> c : initContainers) {
            String img = c.get("image");
            String cname = c.get("name");
            if (img == null || img.isEmpty()) {
                log("  [init] " + cname + " has no image, skipping");
                continue;
            }

            pullImage(img);
            if (pods.get(podName) != pod) {
                log("Pod " + podName + " was deleted before init container '" + cname + "' started");
                deleteVolumes(emptyDirVolumes.values());
                return;
            }
            pod.phase = "Pending";
            pod.initPhase = "Running";
            notifyWatchers(podName, "MODIFIED", pod);

            List<String> envs = envJsonToDockerEnv(c.get("envJson"));
            // Log key env vars to diagnose missing config
            for (String e : envs) if (e.startsWith("INTERNAL_API_HOST") || e.startsWith("WORKLOAD_API_HOST") || e.startsWith("AIRBYTE_INTERNAL") || e.startsWith("AIRBYTE_WORKLOAD") || e.startsWith("MICRONAUT_CONFIG") || e.startsWith("CONTROL_PLANE"))
                log("  [init] key env: " + e);
            if (envs.stream().noneMatch(e -> e.startsWith("INTERNAL_API_HOST")))
                err("INTERNAL_API_HOST not in init env!");
            List<String> binds = buildBinds.apply(c);
            List<String> initArgs = jsonArrayToStringList(c.get("argsJson"));
            List<String> initCmd = jsonArrayToStringList(c.get("commandJson"));
            log("  [init] " + cname + " binds=" + binds + " cmd=" + initCmd + " args=" + initArgs);
            String id = runDockerContainer(podName, cname, img, envs, binds, podNetworkMode, extraNetworks, false, initArgs, initCmd, null);
            if (!id.isEmpty()) {
                log("  [init] " + cname + " running id=" + id.substring(0, Math.min(12, id.length())) + " — waiting...");
                int code = waitContainer(id);
                log("  [init] " + cname + " exited code=" + code);
                dumpContainerLogs(id, podName + "-init");
                removeContainer(id);
                if (code != 0) {
                    err("Pod " + podName + " init container '" + cname + "' FAILED (exit " + code + ") → pod=Failed");
                    pod.initExitCode = code;
                    pod.phase = "Failed";
                    pod.completionTime = iso8601Now();
                    pod.initDone = false;
                    notifyWatchers(podName, "MODIFIED", pod);
                    deleteVolumes(emptyDirVolumes.values());
                    return;
                }
                log("  [init] " + cname + " completed successfully");
            } else {
                // Container creation failed — abort pod
                err("Pod " + podName + " init container '" + cname + "' could not be created → pod=Failed");
                pod.initExitCode = 1;
                pod.phase = "Failed";
                pod.completionTime = iso8601Now();
                pod.initDone = false;
                notifyWatchers(podName, "MODIFIED", pod);
                deleteVolumes(emptyDirVolumes.values());
                return;
            }
        }
        pod.initDone = true;
        log("POD " + podName + " → init done, notifying watchers");
        notifyWatchers(podName, "MODIFIED", pod);

        // ── Phase 2: Run main containers ──────────────────────────────────
        log("POD " + podName + " → PHASE 2: main containers");
        pod.phase = "Running";
        pod.mainRunning = true;
        notifyWatchers(podName, "MODIFIED", pod);

        log("  [main] network mode: " + podNetworkMode);

        List<String> containerIds = new ArrayList<>();
        List<String> containerNames = new ArrayList<>();
        for (Map<String,String> c : mainContainers) {
            String img = c.get("image");
            String cname = c.get("name");
            if (img == null || img.isEmpty()) {
                log("  [main] " + cname + " has no image, skipping");
                continue;
            }

            pullImage(img);
            if (pods.get(podName) != pod) {
                log("Pod " + podName + " was deleted before container '" + cname + "' started");
                break;
            }
            List<String> envs = envJsonToDockerEnv(c.get("envJson"));
            List<String> binds = buildBinds.apply(c);
            List<String> mainArgs = jsonArrayToStringList(c.get("argsJson"));
            List<String> mainCmd = jsonArrayToStringList(c.get("commandJson"));
            log("  [main] starting " + cname + "  binds=" + binds + " cmd=" + mainCmd + " args=" + mainArgs);
            // Set working dir to a writable mount so connector shell scripts can write exitCode.txt etc.
            // Priority: /config (check/discover/orchestrator), then /source, then /dest
            String wdir;
            if (binds.stream().anyMatch(b -> b.endsWith(":/config"))) {
                wdir = "/config";
            } else if (binds.stream().anyMatch(b -> b.endsWith(":/source"))) {
                wdir = "/source";
            } else if (binds.stream().anyMatch(b -> b.endsWith(":/dest"))) {
                wdir = "/dest";
            } else {
                wdir = null;
            }
            if ("orchestrator".equals(cname)) {
                envs = new java.util.ArrayList<>(envs);
                envs.removeIf(e -> e.startsWith("MICRONAUT_SERVER_PORT="));
                envs.removeIf(e -> e.startsWith("SERVER_PORT="));
                envs.removeIf(e -> e.startsWith("PORT="));
                envs.removeIf(e -> e.startsWith("AIRBYTE_CONTAINER_ORCHESTRATOR_PORT="));
                envs.add("MICRONAUT_SERVER_PORT=0");
                envs.add("SERVER_PORT=0");
                envs.add("PORT=0");
                envs.add("AIRBYTE_CONTAINER_ORCHESTRATOR_PORT=0");
                String existingJto = "";
                java.util.Iterator<String> it = envs.iterator();
                while (it.hasNext()) {
                    String e = it.next();
                    if (e.startsWith("JAVA_TOOL_OPTIONS=")) {
                        existingJto = e.substring("JAVA_TOOL_OPTIONS=".length()).trim();
                        it.remove();
                    }
                }
                String forcedPortProp = "-Dmicronaut.server.port=0";
                String mergedJto = existingJto.isEmpty() ? forcedPortProp : (existingJto + " " + forcedPortProp);
                envs.add("JAVA_TOOL_OPTIONS=" + mergedJto);
                mainArgs = forceMicronautRandomPort(mainArgs);
                mainCmd = forceOrchestratorPortInCommand(mainCmd);
            }
            String id = runDockerContainer(podName, cname, img, envs, binds, podNetworkMode, extraNetworks, true, mainArgs, mainCmd, wdir);
            if (!id.isEmpty()) {
                containerIds.add(id);
                containerNames.add(cname);
                log("  [main] " + cname + " started id=" + id.substring(0, Math.min(12, id.length())));
            } else {
                err("  [main] " + cname + " failed to start");
            }
        }

        log("POD " + podName + " → waiting for " + containerIds.size() + " main container(s)");
        // Wait for all main containers to complete
        int exitCode = 0;
        for (int i = 0; i < containerIds.size(); i++) {
            String id = containerIds.get(i);
            String cname = i < containerNames.size() ? containerNames.get(i) : id.substring(0, Math.min(12, id.length()));
            int code = waitContainer(id);
            log("  [main] " + cname + " exited code=" + code);
            if (code != 0) exitCode = code;
            dumpContainerLogs(id, podName + "-" + cname);
            removeContainer(id);
        }

        deleteVolumes(emptyDirVolumes.values());
        pod.phase = exitCode == 0 ? "Succeeded" : "Failed";
        pod.completionTime = iso8601Now();
        pod.mainRunning = false;
        notifyWatchers(podName, "MODIFIED", pod);
        log("POD " + podName + " DONE  phase=" + pod.phase + "  (overall exit=" + exitCode + ")");
    }

    static void deleteVolumes(Collection<String> dockerVols) {
        for (String dockerVol : dockerVols) {
            try { dockerDelete("/v1.41/volumes/" + dockerVol); log("  emptyDir volume " + dockerVol + " deleted"); }
            catch (Exception ignored) {}
        }
    }

    // ── Secrets, kept in the Airbyte database ─────────────────────────────
    // The bootloader stores the dataplane credentials it creates in the Secret
    // airbyte-auth-secrets and verifies them on every later run; the launcher reads them
    // back. Airbyte's own Postgres (DATABASE_URL/USER/PASSWORD, exported by both services
    // that run FakeK8s) gives the two processes one durable store and no node-local state.
    static Connection db() throws SQLException {
        Connection c = DriverManager.getConnection(System.getenv("DATABASE_URL"),
            System.getenv("DATABASE_USER"), System.getenv("DATABASE_PASSWORD"));
        try (Statement st = c.createStatement()) {
            st.execute("CREATE TABLE IF NOT EXISTS fakek8s_secrets (name TEXT PRIMARY KEY, data TEXT NOT NULL)");
        }
        return c;
    }

    // The Secret's data object ({"key":"<base64>",...}), or null when it does not exist.
    static String secretData(String name) throws SQLException {
        try (Connection c = db();
             PreparedStatement q = c.prepareStatement("SELECT data FROM fakek8s_secrets WHERE name = ?")) {
            q.setString(1, name);
            try (ResultSet r = q.executeQuery()) { return r.next() ? r.getString(1) : null; }
        }
    }

    static void putSecret(String name, String data) throws SQLException {
        try (Connection c = db();
             PreparedStatement q = c.prepareStatement("INSERT INTO fakek8s_secrets (name, data) VALUES (?, ?) "
                 + "ON CONFLICT (name) DO UPDATE SET data = EXCLUDED.data")) {
            q.setString(1, name);
            q.setString(2, data);
            q.executeUpdate();
        }
    }

    static void deleteSecret(String name) throws SQLException {
        try (Connection c = db();
             PreparedStatement q = c.prepareStatement("DELETE FROM fakek8s_secrets WHERE name = ?")) {
            q.setString(1, name);
            q.executeUpdate();
        }
    }

    static String secretValue(String name, String key) throws SQLException {
        String data = secretData(name);
        String b64 = data == null ? "" : jsonStr(data, key);
        return b64.isEmpty() ? null : new String(Base64.getDecoder().decode(b64), StandardCharsets.UTF_8);
    }

    static String secretJson(String name, String data) {
        return "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"type\":\"Opaque\",\"metadata\":{\"name\":\""
            + esc(name) + "\",\"namespace\":\"default\",\"resourceVersion\":\"" + RV.incrementAndGet()
            + "\"},\"data\":" + data + "}";
    }

    // The object value of "key" (first occurrence), or null. Brace matching is enough for a
    // Secret's data, whose values are base64.
    static String jsonObject(String json, String key) {
        int k = json.indexOf("\"" + key + "\":{");
        if (k < 0) return null;
        int start = json.indexOf('{', k), depth = 0;
        for (int i = start; i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return json.substring(start, i + 1);
        }
        return null;
    }

    static void sweepLeftovers() {
        try {
            String filter = URLEncoder.encode("{\"label\":[\"airbyte.fakek8s/owner=" + esc(OWNER) + "\"]}", "UTF-8");
            java.util.regex.Matcher c = java.util.regex.Pattern.compile("\"Id\":\"([a-f0-9]+)\"")
                .matcher(dockerGet("/v1.41/containers/json?all=true&filters=" + filter));
            while (c.find()) {
                dockerDelete("/v1.41/containers/" + c.group(1) + "?force=true");
                log("removed leftover container " + c.group(1).substring(0, Math.min(12, c.group(1).length())));
            }
            java.util.regex.Matcher v = java.util.regex.Pattern.compile("\"Name\":\"([^\"]+)\"")
                .matcher(dockerGet("/v1.41/volumes?filters=" + filter));
            while (v.find()) {
                dockerDelete("/v1.41/volumes/" + v.group(1));
                log("removed leftover volume " + v.group(1));
            }
        } catch (Exception e) {
            err("Leftover sweep failed: " + e);
        }
    }

    // ── SSE watch notification ────────────────────────────────────────────
    static void notifyWatchers(String podName, String eventType, PodState pod) {
        pod.resourceVersion = Long.toString(RV.incrementAndGet());
        String event = watchEvent(eventType, pod) + "\n";
        List<PrintWriter> ws = watchers.get(podName);
        if (ws != null) {
            synchronized (ws) {
                Iterator<PrintWriter> it = ws.iterator();
                while (it.hasNext()) {
                    PrintWriter pw = it.next();
                    try {
                        pw.print(event);
                        pw.flush();
                        if (pw.checkError()) it.remove();
                    } catch (Exception e) { it.remove(); }
                }
            }
        }
    }

    // ── HTTP server ───────────────────────────────────────────────────────
    static void sendJson(OutputStream out, int status, String body) throws IOException {
        String statusText = status == 200 ? "OK" : status == 201 ? "Created"
            : status == 204 ? "No Content" : status == 404 ? "Not Found" : "OK";
        byte[] bodyBytes = body.getBytes("UTF-8");
        PrintStream ps = new PrintStream(out, false, "UTF-8");
        ps.print("HTTP/1.1 " + status + " " + statusText + "\r\n");
        ps.print("Content-Type: application/json\r\n");
        ps.print("Content-Length: " + bodyBytes.length + "\r\n");
        ps.print("Connection: close\r\n\r\n");
        out.write(bodyBytes);
        out.flush();
    }

    static long watchTimeoutMillis(String query) {
        for (String part : query.split("&")) {
            if (!part.startsWith("timeoutSeconds=")) continue;
            try {
                long seconds = Long.parseLong(part.substring("timeoutSeconds=".length()));
                return Math.max(1, seconds) * 1_000;
            } catch (NumberFormatException ignored) {}
        }
        return 300_000;
    }

    static void sendWatch(Socket sock, String podName, String query) throws Exception {
        // Send chunked response headers
        PrintStream hdr = new PrintStream(sock.getOutputStream(), false, "UTF-8");
        hdr.print("HTTP/1.1 200 OK\r\n");
        hdr.print("Content-Type: application/json\r\n");
        hdr.print("Transfer-Encoding: chunked\r\n");
        hdr.print("Connection: keep-alive\r\n\r\n");
        hdr.flush();

        PrintWriter pw = new PrintWriter(new OutputStreamWriter(sock.getOutputStream(), "UTF-8"), true) {
            @Override
            public void print(String s) {
                try {
                    byte[] b = s.getBytes("UTF-8");
                    // Chunked encoding: size\r\ndata\r\n
                    String chunk = Integer.toHexString(b.length) + "\r\n" + s + "\r\n";
                    sock.getOutputStream().write(chunk.getBytes("UTF-8"));
                    sock.getOutputStream().flush();
                } catch (Exception e) { setError(); }
            }
        };

        // Send current state as ADDED event first
        boolean alreadyTerminal = false;
        if (pods.containsKey(podName)) {
            PodState existing = pods.get(podName);
            pw.print(watchEvent("ADDED", existing) + "\n");
            log("WATCH " + podName + " opened — current phase=" + existing.phase);
            alreadyTerminal = "Succeeded".equals(existing.phase) || "Failed".equals(existing.phase);
        } else {
            log("WATCH " + podName + " opened — pod NOT YET in registry (will wait)");
        }

        // Register watcher
        watchers.computeIfAbsent(podName, k -> Collections.synchronizedList(new ArrayList<>())).add(pw);

        // Fabric8 commonly starts a watch after it has already observed the pod
        // through a GET/LIST. An ADDED event whose state is terminal is not
        // sufficient for all of its wait paths, so send its final MODIFIED event
        // as well. Keep the watch open afterwards: immediately closing a watch
        // makes Fabric8 reconnect in a tight loop before it consumes the event.
        if (alreadyTerminal) {
            PodState terminal = pods.get(podName);
            if (terminal != null) pw.print(watchEvent("MODIFIED", terminal) + "\n");
            log("WATCH " + podName + " terminal event sent — phase=" +
                (terminal != null ? terminal.phase : "unknown"));
        }

        // Kubernetes keeps a watch open for timeoutSeconds even if its initial
        // event is terminal. The terminal case above additionally sends MODIFIED;
        // all watches remain open for timeoutSeconds unless the client disconnects.
        long timeout = System.currentTimeMillis() + watchTimeoutMillis(query);
        while (System.currentTimeMillis() < timeout && !pw.checkError()) {
            PodState p = pods.get(podName);
            if (!alreadyTerminal && p != null && ("Succeeded".equals(p.phase) || "Failed".equals(p.phase))) {
                // A pod can finish between the initial ADDED event and watcher
                // registration. Send its terminal state here so Fabric8 never
                // waits for a MODIFIED event that it missed.
                pw.print(watchEvent("MODIFIED", p) + "\n");
                log("WATCH " + podName + " resolved → phase=" + p.phase);
                break;
            }
            Thread.sleep(500);
        }
        if (System.currentTimeMillis() >= timeout) {
            log("WATCH " + podName + " closed after requested timeout");
        }

        List<PrintWriter> registered = watchers.get(podName);
        if (registered != null) registered.remove(pw);

        // Send terminal chunk
        try {
            sock.getOutputStream().write("0\r\n\r\n".getBytes("UTF-8"));
            sock.getOutputStream().flush();
        } catch (Exception ignored) {}
    }

    // One header line, without its CRLF; null at end of stream.
    static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        int b;
        while ((b = in.read()) != -1 && b != '\n') line.write(b);
        if (b == -1 && line.size() == 0) return null;
        String s = line.toString("UTF-8");
        return s.endsWith("\r") ? s.substring(0, s.length() - 1) : s;
    }

    static void handleConnection(Socket sock) {
        try (sock) {
            sock.setSoTimeout(60_000);
            InputStream in = new BufferedInputStream(sock.getInputStream());
            String requestLine = readLine(in);
            if (requestLine == null || requestLine.isEmpty()) return;

            String method = requestLine.split(" ")[0];
            String fullPath = requestLine.split(" ").length > 1 ? requestLine.split(" ")[1] : "/";
            String path = fullPath.contains("?") ? fullPath.substring(0, fullPath.indexOf('?')) : fullPath;
            String query = fullPath.contains("?") ? fullPath.substring(fullPath.indexOf('?') + 1) : "";

            // Read headers
            Map<String,String> headers = new LinkedHashMap<>();
            String line;
            while ((line = readLine(in)) != null && !line.isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0) headers.put(line.substring(0, colon).trim().toLowerCase(), line.substring(colon + 1).trim());
            }

            // Read body
            String body = "";
            if (headers.containsKey("content-length")) {
                int len = Integer.parseInt(headers.get("content-length"));
                body = new String(in.readNBytes(len), "UTF-8");
            }

            System.out.println("[FakeK8s] " + method + " " + fullPath);

            // ── Route ────────────────────────────────────────────────────
            boolean isWatch = query.contains("watch=true") || query.contains("watch=1");

            // Discovery
            if ("GET".equals(method) && "/api".equals(path)) {
                sendJson(sock.getOutputStream(), 200, API_VERSIONS); return;
            }
            if ("GET".equals(method) && "/api/v1".equals(path)) {
                sendJson(sock.getOutputStream(), 200, API_RESOURCE_LIST); return;
            }
            if ("GET".equals(method) && "/apis".equals(path)) {
                sendJson(sock.getOutputStream(), 200, API_GROUP_LIST); return;
            }
            if ("GET".equals(method) && "/apis/apps".equals(path)) {
                sendJson(sock.getOutputStream(), 200, APPS_API_GROUP); return;
            }
            if ("GET".equals(method) && "/apis/apps/v1".equals(path)) {
                sendJson(sock.getOutputStream(), 200, APPS_RESOURCE_LIST); return;
            }

            // Secrets (the bootloader's dataplane credentials), stored in the Airbyte database
            if (path.startsWith("/api/v1/namespaces/default/secrets")) {
                String prefix = "/api/v1/namespaces/default/secrets/";
                String name = "POST".equals(method) ? jsonStr(body, "name")   // metadata.name comes first
                    : (path.startsWith(prefix) ? path.substring(prefix.length()) : "");
                try {
                    if ("GET".equals(method) && !name.isEmpty()) {
                        String data = secretData(name);
                        if (data == null) {
                            sendJson(sock.getOutputStream(), 404,
                                "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Failure\"," +
                                "\"message\":\"secrets \\\"" + esc(name) + "\\\" not found\"," +
                                "\"reason\":\"NotFound\",\"code\":404}");
                        } else {
                            sendJson(sock.getOutputStream(), 200, secretJson(name, data));
                        }
                    } else if (!name.isEmpty() && ("POST".equals(method) || "PUT".equals(method) || "PATCH".equals(method))) {
                        String data = jsonObject(body, "data");
                        if (data == null) data = "{}";
                        putSecret(name, data);
                        log("secret " + name + " stored");
                        sendJson(sock.getOutputStream(), "POST".equals(method) ? 201 : 200, secretJson(name, data));
                    } else if ("DELETE".equals(method) && !name.isEmpty()) {
                        deleteSecret(name);
                        sendJson(sock.getOutputStream(), 200,
                            "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Success\"}");
                    } else {
                        sendJson(sock.getOutputStream(), 200,
                            "{\"apiVersion\":\"v1\",\"kind\":\"SecretList\",\"metadata\":{},\"items\":[]}");
                    }
                } catch (SQLException e) {
                    err("secret " + name + " store failed: " + e.getMessage());
                    sendJson(sock.getOutputStream(), 500,
                        "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Failure\",\"code\":500}");
                }
                return;
            }

            // Namespace
            if ("GET".equals(method) && path.startsWith("/api/v1/namespaces/default") && !path.contains("/pods")) {
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"Namespace\"," +
                    "\"metadata\":{\"name\":\"default\"},\"status\":{\"phase\":\"Active\"}}");
                return;
            }

            // ResourceQuota list (launcher checks available resources)
            if ("GET".equals(method) && path.contains("/resourcequotas")) {
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"ResourceQuotaList\"," +
                    "\"metadata\":{},\"items\":[]}");
                return;
            }

            // Node list (launcher may check node capacity)
            if ("GET".equals(method) && path.equals("/api/v1/nodes")) {
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"NodeList\"," +
                    "\"metadata\":{},\"items\":[{\"apiVersion\":\"v1\",\"kind\":\"Node\"," +
                    "\"metadata\":{\"name\":\"docker-swarm-node\"}," +
                    "\"status\":{\"allocatable\":{\"cpu\":\"8\",\"memory\":\"32Gi\"}," +
                    "\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}]}");
                return;
            }

            // ConfigMaps (launcher may create them for connector config)
            if (path.contains("/configmaps")) {
                if ("POST".equals(method)) {
                    String name = jsonStr(body, "name");
                    if (name.isEmpty()) name = "resource-" + System.currentTimeMillis();
                    sendJson(sock.getOutputStream(), 201,
                        "{\"apiVersion\":\"v1\",\"kind\":\"Secret\"," +
                        "\"metadata\":{\"name\":\"" + esc(name) + "\",\"namespace\":\"default\"}}");
                } else if ("DELETE".equals(method)) {
                    sendJson(sock.getOutputStream(), 200,
                        "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Success\"}");
                } else {
                    sendJson(sock.getOutputStream(), 200,
                        "{\"apiVersion\":\"v1\",\"kind\":\"SecretList\"," +
                        "\"metadata\":{},\"items\":[]}");
                }
                return;
            }

            // Pod LIST (PodSweeper, label selector queries)
            if ("GET".equals(method) && (
                    path.equals("/api/v1/namespaces/default/pods") ||
                    path.equals("/api/v1/pods")) && !isWatch) {
                sendJson(sock.getOutputStream(), 200, podListJson(podsMatchingLabelSelector(query)));
                return;
            }

            // Pod WATCH (list + watch=true, or field-selector watch)
            if ("GET".equals(method) && (
                    path.equals("/api/v1/namespaces/default/pods") ||
                    path.equals("/api/v1/pods")) && isWatch) {
                // Extract pod name from fieldSelector
                String fs = query;
                String podName = "";
                for (String part : fs.split("&")) {
                    if (part.startsWith("fieldSelector=")) {
                        String fv = part.substring(14);
                        // metadata.name=<name>
                        for (String f : fv.split(",|%2C")) {
                            if (f.startsWith("metadata.name=") || f.startsWith("metadata.name%3D")) {
                                podName = f.replaceFirst("metadata.name[=%3D]+", "");
                                podName = URLDecoder.decode(podName, "UTF-8");
                            }
                        }
                    }
                }
                if (podName.isEmpty()) {
                    // Watch on all pods: send current state then keep alive
                    sendWatch(sock, "__all__", query);
                } else {
                    sendWatch(sock, podName, query);
                }
                return;
            }

            // Pod CREATE
            if ("POST".equals(method) && (
                    path.equals("/api/v1/namespaces/default/pods") ||
                    path.equals("/api/v1/namespaces/pods"))) {
                String podName = extractPodName(body);
                log(">>> POD CREATE POST: " + podName);
                // Log images for debugging
                List<Map<String,String>> ic = extractContainers(body, "initContainers");
                List<Map<String,String>> mc = extractContainers(body, "containers");
                for (var c : ic) log("  [init] " + c.get("name") + " image=" + c.get("image"));
                for (var c : mc) log("  [main] " + c.get("name") + " image=" + c.get("image"));
                launchPod(body);
                PodState pod = pods.get(podName);
                sendJson(sock.getOutputStream(), 201, pod != null ? podToJson(pod) :
                    "{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"" + esc(podName) + "\"}}");
                return;
            }

            // Pod GET by name
            if ("GET".equals(method) && path.startsWith("/api/v1/namespaces/default/pods/")) {
                String podName = path.substring("/api/v1/namespaces/default/pods/".length());
                if (podName.contains("/")) podName = podName.substring(0, podName.indexOf('/'));
                if (isWatch) {
                    sendWatch(sock, podName, query);
                } else {
                    PodState pod = pods.get(podName);
                    if (pod == null) {
                        sendJson(sock.getOutputStream(), 404,
                            "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Failure\"," +
                            "\"reason\":\"NotFound\",\"code\":404}");
                    } else {
                        sendJson(sock.getOutputStream(), 200, podToJson(pod));
                    }
                }
                return;
            }

            // Pod DELETE
            if ("DELETE".equals(method) && path.startsWith("/api/v1/namespaces/default/pods/")) {
                String podName = path.substring("/api/v1/namespaces/default/pods/".length());
                PodState pod = pods.remove(podName);
                if (pod != null) {
                    notifyWatchers(podName, "DELETED", pod);
                    // Stop any Docker containers for this pod
                    exec.submit(() -> {
                        try {
                            String resp = dockerGet("/v1.41/containers/json?all=true&filters=" +
                                URLEncoder.encode("{\"label\":[\"airbyte.fakek8s/owner=" + esc(OWNER)
                                    + "\",\"airbyte.fakek8s/pod=" + esc(podName) + "\"]}", "UTF-8"));
                            // Extract IDs and stop them
                            java.util.regex.Matcher m = java.util.regex.Pattern.compile("\"Id\":\"([a-f0-9]+)\"").matcher(resp);
                            while (m.find()) {
                                String cid = m.group(1);
                                dockerPost("/v1.41/containers/" + cid + "/stop", "{}");
                                dockerDelete("/v1.41/containers/" + cid + "?force=true");
                            }
                        } catch (Exception ignored) {}
                    });
                }
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Success\"}");
                return;
            }

            // Pod PATCH (launcher uses server-side apply / PATCH?fieldManager=fabric8 to create pods)
            if ("PATCH".equals(method) && path.startsWith("/api/v1/namespaces/default/pods/")) {
                String podName = path.substring("/api/v1/namespaces/default/pods/".length());
                if (podName.contains("/")) podName = podName.substring(0, podName.indexOf('/'));
                PodState pod = pods.get(podName);
                if (pod == null && body != null && !body.isEmpty()) {
                    // Server-side apply CREATE: treat as pod creation.
                    // Use the URL-path pod name as authoritative — do NOT rely on
                    // extractPodName(body) which can pick up a wrong nested "name" field.
                    log(">>> POD CREATE PATCH (server-side apply): " + podName);
                    // Log images for debugging
                    List<Map<String,String>> ic = extractContainers(body, "initContainers");
                    List<Map<String,String>> mc = extractContainers(body, "containers");
                    for (var c : ic) log("  [init] " + c.get("name") + " image=" + c.get("image") + " args=" + c.get("argsJson") + " cmd=" + c.get("commandJson"));
                    for (var c : mc) log("  [main] " + c.get("name") + " image=" + c.get("image") + " args=" + c.get("argsJson") + " cmd=" + c.get("commandJson"));
                    launchPod(body, podName);
                    pod = pods.get(podName);
                }
                if (pod == null) pod = new PodState(podName, "{}");
                sendJson(sock.getOutputStream(), 200, podToJson(pod));
                return;
            }

            // Fallback: 200 empty list for unhandled GETs, 201 for POSTs
            err("Unhandled: " + method + " " + path);
            if ("GET".equals(method)) {
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"List\",\"metadata\":{},\"items\":[]}");
            } else if ("POST".equals(method)) {
                sendJson(sock.getOutputStream(), 201, "{}");
            } else {
                sendJson(sock.getOutputStream(), 200,
                    "{\"apiVersion\":\"v1\",\"kind\":\"Status\",\"status\":\"Success\"}");
            }
        } catch (Exception e) {
            System.err.println("[FakeK8s] Handler error: " + e);
        }
    }

    public static void main(String[] args) throws Exception {
        // `FakeK8s get-secret <name> <key>` prints one decoded value, or exits 1 while it
        // does not exist yet (the launcher waits on it for the dataplane credentials).
        if (args.length == 3 && "get-secret".equals(args[0])) {
            String value = null;
            try { value = secretValue(args[1], args[2]); }
            catch (SQLException e) { System.err.println("[FakeK8s] get-secret: " + e.getMessage()); }
            if (value == null) System.exit(1);
            System.out.print(value);
            return;
        }
        if (!OWNER.isEmpty()) sweepLeftovers();
        log("Starting fake Kubernetes API on :6443");
        ServerSocket ss = new ServerSocket(6443, 128, InetAddress.getLoopbackAddress());
        while (true) {
            final Socket sock = ss.accept();
            exec.submit(() -> handleConnection(sock));
        }
    }
}

