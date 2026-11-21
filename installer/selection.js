// Resolve a validated manifest. Only interactive mode calls choose, with literal fzf lines.
function resolveSelection(manifest, mode, value, language, choose) {
  const groups = manifest.groups;
  const profiles = manifest.profiles;
  const names = new Set(groups.map(group => group.name));
  let wanted;

  function profile(name) {
    return profiles && Object.prototype.hasOwnProperty.call(profiles, name)
      ? profiles[name] : undefined;
  }

  switch (mode) {
    case 'none': {
      const defaults = profile('default');
      wanted = defaults ? new Set(defaults) : names;
      break;
    }
    case 'all':
      wanted = names;
      break;
    case 'profile': {
      if (!value) fail('missing_option_value', '--profile');
      const entries = profile(value);
      if (!entries) fail('unknown_profile', value);
      wanted = new Set(entries);
      break;
    }
    case 'prompt': {
      if (!value) fail('missing_option_value', '--prompt');
      const defaults = profile('default');
      if (!defaults) fail('no_default_profile');
      const prompts = new Set(groups.filter(group => group.kind === 'prompt').map(group => group.name));
      if (!prompts.has(value)) fail('unknown_prompt', value);
      wanted = new Set(defaults.filter(name => !prompts.has(name)));
      wanted.add(value);
      break;
    }
    case 'groups':
      if (!value) fail('missing_option_value', '--groups');
      wanted = new Set();
      for (const part of value.split(',')) {
        const name = part.trim();
        if (!name) fail('empty_group_selection');
        if (!names.has(name)) fail('unknown_group', name);
        wanted.add(name);
      }
      break;
    case 'interactive': {
      const locale = language === 'zh-TW' || language === 'zh_TW' ? 'zh-TW' : 'en';
      const candidates = groups.map(group => group.name + '\t' + group.description[locale]);
      const records = new Set(candidates);
      const lines = choose(candidates);
      if (!lines.length) fail('empty_selection');
      wanted = new Set();
      for (const line of lines) {
        if (!line) fail('fzf_failed', 'empty_record');
        const tab = line.indexOf('\t');
        if (tab !== -1) {
          if (!records.has(line)) fail('fzf_failed', 'invalid_format', line);
          wanted.add(line.slice(0, tab));
        } else {
          // Name-only fzf output uses the legacy lowercase grammar even in schema 2.
          if (!/^[a-z][a-z0-9_-]*$/.test(line)) fail('fzf_failed', 'invalid_format', line);
          if (!names.has(line)) fail('fzf_failed', 'unknown_record', line);
          wanted.add(line);
        }
      }
      break;
    }
    default:
      fail('selection_conflict');
  }

  const selected = [];
  const unselected = [];
  let hasPrompt = false;
  for (const group of groups) {
    if (wanted.has(group.name)) {
      if (group.kind === 'prompt') {
        if (hasPrompt) fail('prompt_conflict');
        hasPrompt = true;
      }
      selected.push(group.name);
    } else {
      unselected.push(group.name);
    }
  }
  return {selected, unselected};
}
