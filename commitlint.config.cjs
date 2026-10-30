// commitlint.config.cjs — Config Stub (ADR-0033).
// Extends the shared commitlint config in the Shared Config Directory
// (`.standards-config/`, provisioned by `mise bootstrap --only repos,tools`).
// Repository rules go after `extends`, in commitlint's own syntax.
module.exports = { extends: ['./.standards-config/config/commitlint.cjs'] };
