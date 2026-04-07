# AI Verify Zig/Mojo migration facts

service("aiverify").
runtime("zig_bridge").
runtime("python_compat").
runtime("mojo_primitives").
runtime("mojo_ffi_optional").
target_parity("100_percent").

component("apigw").
component("test_engine").
component("test_engine_worker").
component("metrics_primitives").
component("apigw_preflight_config").
component("apigw_hana_profile_parity_smoke").
component("apigw_gid_cid_validator").
component("apigw_file_path_helpers").
component("apigw_file_utils_helpers").
component("apigw_plugin_storage_layout_helpers").
component("apigw_plugin_storage_layout_s3_mode").
component("apigw_data_storage_layout_helpers").
component("apigw_artifact_io_local").
component("apigw_model_dataset_io_local").
component("apigw_model_dataset_dir_sidecar_local").
component("apigw_plugin_archive_io_local").
component("apigw_plugin_archive_io_hana_parity_smoke").
component("apigw_plugin_mdx_bundle_io_local").
component("apigw_plugin_backup_io_local").
component("plugin_gid_normalization").
component("nonblocking_parity_smoke").
component("worker_reclaim_parity_smoke").
component("worker_reclaim_invalid_start_parity_smoke").
component("mojo_ffi_ci_smoke").
component("mojo_ffi_ci_build").

migrated("worker_reclaim_loop").
bridge_enabled("worker_reclaim_loop").

migrated("metrics_primitives").
bridge_enabled("metrics_primitives").

migrated("apigw_preflight_config").
bridge_enabled("apigw_preflight_config").

migrated("apigw_hana_profile_parity_smoke").
bridge_enabled("apigw_hana_profile_parity_smoke").

migrated("apigw_gid_cid_validator").
bridge_enabled("apigw_gid_cid_validator").

migrated("apigw_file_path_helpers").
bridge_enabled("apigw_file_path_helpers").

migrated("apigw_file_utils_helpers").
bridge_enabled("apigw_file_utils_helpers").

migrated("apigw_plugin_storage_layout_helpers").
bridge_enabled("apigw_plugin_storage_layout_helpers").

migrated("apigw_plugin_storage_layout_s3_mode").
bridge_enabled("apigw_plugin_storage_layout_s3_mode").

migrated("apigw_data_storage_layout_helpers").
bridge_enabled("apigw_data_storage_layout_helpers").

migrated("apigw_artifact_io_local").
bridge_enabled("apigw_artifact_io_local").

migrated("apigw_model_dataset_io_local").
bridge_enabled("apigw_model_dataset_io_local").

migrated("apigw_model_dataset_dir_sidecar_local").
bridge_enabled("apigw_model_dataset_dir_sidecar_local").

migrated("apigw_plugin_archive_io_local").
bridge_enabled("apigw_plugin_archive_io_local").

migrated("apigw_plugin_archive_io_hana_parity_smoke").
bridge_enabled("apigw_plugin_archive_io_hana_parity_smoke").

migrated("apigw_plugin_mdx_bundle_io_local").
bridge_enabled("apigw_plugin_mdx_bundle_io_local").

migrated("apigw_plugin_backup_io_local").
bridge_enabled("apigw_plugin_backup_io_local").

migrated("plugin_gid_normalization").
bridge_enabled("plugin_gid_normalization").

migrated("nonblocking_parity_smoke").
bridge_enabled("nonblocking_parity_smoke").

migrated("worker_reclaim_parity_smoke").
bridge_enabled("worker_reclaim_parity_smoke").

migrated("worker_reclaim_invalid_start_parity_smoke").
bridge_enabled("worker_reclaim_invalid_start_parity_smoke").

migrated("mojo_ffi_ci_smoke").
bridge_enabled("mojo_ffi_ci_smoke").

migrated("mojo_ffi_ci_build").
bridge_enabled("mojo_ffi_ci_build").
