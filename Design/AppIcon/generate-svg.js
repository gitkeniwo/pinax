#!/usr/bin/env node
// Writes pinax.svg from pinax.json (or: generate-svg.js <params.json> <out.svg>).
const fs = require('fs'), path = require('path');
const render = require('./icon.js');
const params = process.argv[2] || path.join(__dirname, 'pinax.json');
const out = process.argv[3] || path.join(__dirname, 'pinax.svg');
fs.writeFileSync(out, render(JSON.parse(fs.readFileSync(params, 'utf8'))));
