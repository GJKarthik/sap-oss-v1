// Example runtime-config.js for production-style browser access behind an OIDC edge
// (oauth2-proxy, IAS, XSUAA approuter). Mount as runtime-config.js for the training-web
// deployment or merge into ConfigMap training-web-runtime-config — see training-edge-auth-overlay.yaml.
window.__TRAINING_CONFIG__ = {
  apiBaseUrl: '/api',
  authMode: 'edge',
  requireAuth: true,
  loginUrl: '/oauth2/start?rd=%2F',
  logoutUrl: '/oauth2/sign_out',
};
