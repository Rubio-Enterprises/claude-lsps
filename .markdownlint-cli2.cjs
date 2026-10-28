// .markdownlint-cli2.cjs — Config Stub (ADR-0033, ADR-0033).
// Requires the shared markdownlint-cli2 options from the Shared Config
// Checkout; a missing file fails markdownlint-cli2. Compose each field you
// change explicitly, for example:
//
//   config: { ...base.config, MD060: false },
//   ignores: [...base.ignores, 'docs/**'],
'use strict';

const base = require('./.standards-config/config/markdownlint-cli2.cjs');

module.exports = {
  ...base,
};
