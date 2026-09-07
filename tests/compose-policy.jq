# Check the parsed, normalized Compose model, not coincidental YAML text.
def volume_mount($service; $source; $target):
  any(.services[$service].volumes[]?;
      .type == "volume" and .source == $source and .target == $target
      and (.read_only // false) == false);
def contract:
  . as $model |
  (.services | type == "object" and length > 0) and
  (["mlflow-postgres", "mlflow-storage", "mlflow-create-bucket", "mlflow",
    "laminar-postgres", "laminar-clickhouse", "laminar-rabbitmq",
    "laminar-quickwit", "laminar-app-server", "laminar-frontend",
    "laminar-bootstrap", "otel-collector"] |
    all(.[]; $model.services[.] | type == "object")) and
  ([.services[].ports[]?] | length > 0) and
  all(.services[];
    (.network_mode // "") != "host" and (.privileged // false) == false and
    all(.ports[]?; .host_ip == "127.0.0.1" and
      (.published | tonumber) > 0 and (.published | tonumber) <= 65535) and
    all(.volumes[]?; .type != "bind" or .read_only == true)) and
  (.networks.default.external == true) and
  volume_mount("mlflow-postgres"; "mlflow-postgres-data"; "/var/lib/postgresql/data") and
  volume_mount("mlflow-storage"; "mlflow-storage-data"; "/data") and
  volume_mount("laminar-postgres"; "laminar-postgres-data"; "/var/lib/postgresql/data") and
  volume_mount("laminar-clickhouse"; "laminar-clickhouse-data"; "/var/lib/clickhouse") and
  volume_mount("laminar-clickhouse"; "laminar-clickhouse-logs"; "/var/log/clickhouse-server") and
  volume_mount("laminar-quickwit"; "laminar-quickwit-data"; "/quickwit/qwdata") and
  all(.services[].volumes[]?; .type != "volume" or
    (.source as $source | $model.volumes | has($source))) and
  (.services["laminar-app-server"].environment.LAMINAR_TELEMETRY_DISABLED == "true");
if contract then true else error("deployment model violates bounded local standards") end
