const target =
  process.env.SAP_API_UPSTREAM ||
  process.env.API_PROXY_TARGET ||
  "http://127.0.0.1:8000";

module.exports = {
  "/api": {
    target,
    secure: false,
    changeOrigin: true,
    logLevel: "warn",
    proxyTimeout: 60000,
    timeout: 60000,
  },
};
