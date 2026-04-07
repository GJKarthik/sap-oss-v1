# Bridge-mode declarations while migrating Python modules to Zig/Mojo.

Decl bridge_mode(mode: /string).
Decl module_owner(module: /string, owner: /string).

bridge_mode("python_compat").
bridge_mode("mojo_ffi_optional").
module_owner("aiverify-apigw", "zig").
module_owner("aiverify-test-engine", "zig").
module_owner("aiverify-test-engine-worker", "zig").
module_owner("apigw_preflight_config", "zig").
module_owner("apigw_hana_profile_parity_smoke", "zig").
module_owner("apigw_gid_cid_validator", "zig").
module_owner("apigw_file_path_helpers", "zig").
module_owner("apigw_file_utils_helpers", "zig").
module_owner("apigw_plugin_storage_layout_helpers", "zig").
module_owner("apigw_plugin_storage_layout_s3_mode", "zig").
module_owner("apigw_data_storage_layout_helpers", "zig").
module_owner("apigw_artifact_io_local", "zig").
module_owner("apigw_model_dataset_io_local", "zig").
module_owner("apigw_model_dataset_dir_sidecar_local", "zig").
module_owner("apigw_plugin_archive_io_local", "zig").
module_owner("apigw_plugin_archive_io_hana_parity_smoke", "zig").
module_owner("apigw_plugin_mdx_bundle_io_local", "zig").
module_owner("apigw_plugin_backup_io_local", "zig").
module_owner("worker_reclaim_loop", "zig").
module_owner("metrics_primitives", "mojo").
module_owner("plugin_gid_normalization", "mojo").
module_owner("nonblocking_parity_smoke", "zig").
module_owner("worker_reclaim_parity_smoke", "zig").
module_owner("worker_reclaim_invalid_start_parity_smoke", "zig").
module_owner("mojo_ffi_ci_smoke", "zig").
module_owner("mojo_ffi_ci_build", "zig").
