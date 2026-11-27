const projectName = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const numberedId = /^(.+)-([0-9]+)$/;

function assignTaskId({ id, repo, prefix }, activeIds, reservedIds) {
  const usedIds = [...activeIds, ...reservedIds];
  const savedProject = usedIds.reduce((longest, used) => {
    const candidate = numberedId.exec(used)?.[1];
    return candidate && candidate.length > longest.length &&
      id?.toLowerCase().startsWith(`${candidate.toLowerCase()}-`) ? candidate : longest;
  }, '');
  const project = repo ?? prefix ?? numberedId.exec(id ?? '')?.[1] ??
    (savedProject || id?.match(/^(.+)-[^-]*$/)?.[1]);
  if (!project || !projectName.test(project)) {
    throw new Error('Pass --repo <project> or --mint --prefix <project> to name the project for a numbered task ID');
  }

  let highest = 0n;
  for (const used of usedIds) {
    const parts = numberedId.exec(used);
    if (parts?.[1].toLowerCase() !== project.toLowerCase()) continue;
    const number = BigInt(parts[2]);
    if (number > highest) highest = number;
  }
  const next = `${project}-${highest + 1n}`;
  if (repo && prefix && repo !== prefix) {
    throw new Error(`--prefix must match --repo; next free task ID is ${next}`);
  }
  if (id === undefined) return next;
  const parts = numberedId.exec(id);
  if (id === next || (parts?.[1] === project && /^[1-9][0-9]*$/.test(parts[2]) && activeIds.includes(id))) return id;
  throw new Error(`Cannot add task "${id}"; use the next free task ID: ${next}`);
}

function followupMarker(key, mint, json) {
  if (key === undefined) return null;
  if (!mint || !json || !/^[A-Za-z0-9._-]+$/.test(key)) {
    throw new Error('--followup-key requires a slug key, --mint, and --json');
  }
  return `Follow-up id: ${key}`;
}

function hasFollowupMarker(body, marker) {
  const legacy = marker.replace(/^Follow-up id: /, 'Follow-up key: ');
  return body.split(/\r?\n/).some(line => line === marker || line === legacy);
}

module.exports = { assignTaskId, followupMarker, hasFollowupMarker };
