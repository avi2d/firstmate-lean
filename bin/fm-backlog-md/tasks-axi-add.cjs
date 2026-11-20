const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { assignTaskId, followupMarker, hasFollowupMarker } = require('./task-id.cjs');

const values = ['repo', 'kind', 'body', 'body-file', 'blocked-by', 'pr', 'report', 'priority', 'title', 'prefix', 'followup-key'];
const switches = ['mint', 'queue', 'json'];

function readOptionalFile(file) {
  const stat = fs.statSync(file, { throwIfNoEntry: false });
  if (!stat) return '';
  if (!stat.isFile()) throw new Error(`${file}: expected a regular file`);
  return fs.readFileSync(file, 'utf8');
}

function configuredArchive(config) {
  let markdown = false;
  let archive;
  for (const line of readOptionalFile(config).split('\n')) {
    const section = /^\s*\[([^\]]+)\]\s*(?:#.*)?$/.exec(line);
    if (section) markdown = section[1].trim() === 'markdown';
    if (!markdown) continue;
    const match = /^\s*archive\s*=\s*(["'])(.*?)\1\s*(?:#.*)?$/.exec(line);
    if (match) archive = match[2];
  }
  return archive;
}

function markdownItems(file, key, marker) {
  const bullet = /^- (?:\[[ x]\] ([A-Za-z0-9._-]+)|\*\*([A-Za-z0-9._-]+)\*\*)(?= - |: )/;
  const ids = [];
  let current;
  let replay;
  for (const line of readOptionalFile(file).split(/\r?\n/)) {
    const match = bullet.exec(line);
    if (match) {
      current = match[1] ?? match[2];
      ids.push(current);
      if (current === key) replay = current;
    } else if (current && marker && line === `  ${marker}`) {
      replay = current;
    } else if (line && !line.startsWith('  ')) {
      current = undefined;
    }
  }
  return { ids, replay };
}

function adapterOutput(args) {
  const output = spawnSync('tasks-axi', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (output.error) throw output.error;
  if (output.status !== 0) throw new Error(output.stderr.trim() || output.stdout.trim() || `tasks-axi ${args[0]} failed`);
  return output.stdout;
}

function adapterFollowup(ids, marker) {
  return ids.find(id => {
    const shown = adapterOutput(['show', id, '--full']);
    const body = /^  body: (.*)$/m.exec(shown)?.[1];
    return body && hasFollowupMarker(body.startsWith('"') ? JSON.parse(body) : body, marker);
  });
}

function activeAdapterIds() {
  const lines = adapterOutput(['list']).split('\n');
  if (lines.includes('count: 0')) return [];
  const start = lines.findIndex(line => /^tasks\[\d+\]\{id,/.test(line));
  if (start < 0) throw new Error('tasks-axi list did not return a task table');
  const count = Number(/^tasks\[(\d+)\]/.exec(lines[start])[1]);
  const ids = lines.slice(start + 1, start + 1 + count).map(line => /^\s+([A-Za-z0-9._-]+),/.exec(line)?.[1]);
  if (ids.length !== count || ids.includes(undefined)) throw new Error('tasks-axi list returned an invalid task table');
  return ids;
}

function parseAdd(args) {
  const positionals = [];
  const forwarded = [];
  const options = Object.create(null);
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') {
      positionals.push(...args.slice(i + 1));
      break;
    }
    if (!arg.startsWith('-')) {
      positionals.push(arg);
      continue;
    }
    const match = /^--([^=]+)(?:=([^]*))?$/.exec(arg);
    const flag = match?.[1];
    const inline = match?.[2];
    if (switches.includes(flag) && inline === undefined) {
      if (flag !== 'mint') forwarded.push(arg);
      options[flag] = true;
    } else if (values.includes(flag)) {
      const value = inline ?? args[++i];
      if (!value || (inline === undefined && value.startsWith('--'))) throw new Error(`--${flag} requires a value`);
      if (flag === 'blocked-by') forwarded.push(`--${flag}=${value}`);
      else {
        if (Object.hasOwn(options, flag)) throw new Error(`Pass --${flag} only once`);
        if (!['prefix', 'title', 'followup-key'].includes(flag)) forwarded.push(`--${flag}=${value}`);
        options[flag] = value;
      }
    } else {
      throw new Error(`Unknown add flag: ${arg}`);
    }
  }

  const expected = (options.mint ? 0 : 1) + (options.title ? 0 : 1);
  if (positionals.length !== expected) throw new Error('Pass <project>-<number> "<title>", or "<title>" --mint --prefix <project>');
  if (!options.mint && options.prefix) throw new Error('--prefix can only be used with --mint');
  return {
    id: options.mint ? undefined : positionals[0],
    title: options.title ?? positionals.at(-1),
    repo: options.repo ?? (options.mint ? options.prefix : undefined),
    prefix: options.prefix,
    followupKey: options['followup-key'],
    marker: followupMarker(options['followup-key'], options.mint, options.json),
    body: options.body,
    forwarded,
  };
}

function add(args) {
  if (args.includes('--help') || args.includes('-h')) {
    console.log('usage: fm-tasks-axi.sh add ("<title>" --mint --prefix <project> | <project>-<number> "<title>") [flags]');
    console.log('Use --repo <project> in place of --prefix <project> when minting.');
    console.log('flags:', [...values.map(flag => `--${flag} <value>`), ...switches.map(flag => `--${flag}`)].join(', '));
    return;
  }
  const request = parseAdd(args);
  const { followupKey, marker } = request;
  const file = process.env.TASKS_AXI_FILE;
  const active = file ? markdownItems(file, followupKey, marker) : { ids: activeAdapterIds() };
  const archive = file && (configuredArchive('.tasks.toml') ??
    configuredArchive(path.join(os.homedir(), '.tasks-axi', 'config.toml')) ??
    path.join(path.dirname(file), 'done-archive.md'));
  const reserved = archive ? markdownItems(archive, followupKey, marker) : { ids: [] };
  const replay = active.replay ?? reserved.replay ??
    (!file && marker ? active.ids.find(id => id === followupKey) ?? adapterFollowup(active.ids, marker) : undefined);
  if (replay) {
    console.log(JSON.stringify({ ok: true, action: 'add', already: true, task: { id: replay } }));
    return;
  }
  const id = assignTaskId(request, active.ids, reserved.ids);
  const forwarded = request.forwarded.filter(arg => !marker || !arg.startsWith('--body='));
  if (marker) {
    if (forwarded.some(arg => arg.startsWith('--body-file='))) throw new Error('--followup-key does not accept --body-file');
    forwarded.push(`--body=${[request.body, marker].filter(Boolean).join('\n\n')}`);
  }
  if (request.prefix && !forwarded.some(arg => arg.startsWith('--repo='))) forwarded.push(`--repo=${request.repo}`);
  const result = spawnSync('tasks-axi', ['add', id, `--title=${request.title}`, ...forwarded], { stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 2;
}

try {
  add(process.argv.slice(3));
} catch (error) {
  console.error(`fm-tasks-axi: ${error.message}`);
  process.exitCode = 2;
}
