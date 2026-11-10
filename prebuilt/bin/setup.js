#!/usr/bin/env node
// dsh-termux-setup — the entry point that always works.
//
// npm >= 12 does not run a dependency's postinstall unless it is allow-listed,
// and it still exits 0. Relying on postinstall alone therefore produced an
// empty install ("added 1 package", no dsh). The tarball ships this bin so the
// deployment can be triggered explicitly:
//
//     npm i -g <tarball> && dsh-termux-setup
//
// `bin/dsh` also calls into this file when it cannot find the deployment, so
// `dsh` alone is enough on a fresh install.

"use strict";

require("../install.js").main();
