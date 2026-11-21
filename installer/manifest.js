// Validate the checkout's JSON before its values cross into shell/TSV consumers.
function parseManifest(text, isPackageDirectory, tables, isCheckoutFile) {
  function invalid(reason, ...args) { fail('invalid_manifest', reason, ...args); }
  function has(obj, key) { return Object.prototype.hasOwnProperty.call(obj, key); }
  function record(value, reason, ...args) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) invalid(reason, ...args);
    return value;
  }
  function array(value, reason, ...args) {
    if (!Array.isArray(value)) invalid(reason, ...args);
    return value;
  }
  function required(obj, key, reason, ...args) {
    if (!has(obj, key)) invalid(reason, ...args);
    return obj[key];
  }
  function keys(obj, allowed, reason, ...args) {
    if (Object.keys(obj).some(key => !allowed.includes(key))) invalid(reason, ...args);
  }
  function unique(seen, value, reason) {
    if (seen.has(value)) invalid(reason, value);
    seen.add(value);
  }
  function flag(obj, key, reason, ...args) {
    if (!has(obj, key)) return 0;
    if (typeof obj[key] !== 'boolean') invalid(reason, ...args);
    return obj[key] ? 1 : 0;
  }

  const asciiToken = /^[A-Za-z0-9._@+-]+$/;
  const legacyName = /^[a-z][a-z0-9_-]*$/;
  const control = /[\x00-\x1f\x7f]/;
  function token(value, reason, index, pattern = asciiToken) {
    if (typeof value !== 'string') invalid(reason, index);
    if (!pattern.test(value)) invalid(reason, value);
    return value;
  }
  function fieldText(value, emptyReason, controlReason, owner) {
    if (typeof value !== 'string' || !value.length) invalid(emptyReason, owner);
    if (control.test(value)) invalid(controlReason, owner);
  }
  function localized(value, field, owner) {
    record(value, field === 'notes' ? 'feature_invalid_notes' : 'description_not_object', owner);
    required(value, 'en', field + '_missing_en', owner);
    required(value, 'zh-TW', field + '_missing_zhtw', owner);
    keys(value, ['en', 'zh-TW'], field + '_unknown_key', owner);
    fieldText(value.en, field + '_empty_en', field + '_control_char', owner);
    fieldText(value['zh-TW'], field + '_empty_zhtw', field + '_control_char', owner);
  }

  let manifest;
  try { manifest = JSON.parse(text); } catch (error) { invalid('malformed_syntax'); }

  // JSON.parse cannot distinguish 1 from 1.0 or retain all 64-bit hotkey IDs.
  // Only for such inputs, keep the original number spellings alongside the parsed types.
  let spellings;
  if (/\d(?:[.eE]|\d{15})/.test(text)) {
    const stringsOrNumbers = /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
    spellings = JSON.parse(text.replace(stringsOrNumbers, s => s[0] === '"' ? s : '"' + s + '"'));
  }
  function integer(value, spelling) {
    if (!Number.isInteger(value)) return null;
    if (spelling !== undefined && /[.eE]/.test(spelling)) return null;
    if (Number.isSafeInteger(value)) return value;
    const digits = spelling.replace(/^-/, '');
    const limit = value < 0 ? '9223372036854775808' : '18446744073709551615';
    return digits.length < limit.length || (digits.length === limit.length && digits <= limit) ? spelling : null;
  }
  record(manifest, 'root_not_object');
  const schema = integer(required(manifest, 'schema', 'missing_schema'), spellings && spellings.schema);
  required(manifest, 'groups', 'missing_groups');
  if (schema === null) invalid('schema_not_integer');
  if (schema !== 1 && schema !== 2) invalid('unsupported_schema', schema);
  const rootKeys = ['schema', 'groups', 'profiles'];
  if (schema === 2) rootKeys.push('fonts', 'brew', 'features');
  const unknownKeys = Object.keys(manifest).filter(key => !rootKeys.includes(key));
  if (unknownKeys.length) {
    const residual = Object.create(null);
    for (const key of unknownKeys) residual[key] = manifest[key];
    invalid('unknown_top_key', JSON.stringify(residual));
  }

  for (const key of ['groups', 'fonts', 'brew', 'brew_taps', 'group_brew_deps', 'features',
                     'feature_brew', 'feature_copy', 'feature_hotkeys', 'feature_notes']) {
    tables[key + '.tsv'] = [];
  }

  function preview(lines, groupIndex) {
    array(lines, 'group_preview_not_array', groupIndex).forEach((line, i) => {
      array(line, 'group_preview_line_not_array', groupIndex, i).forEach((seg, j) => {
        record(seg, 'group_preview_segment_not_object', groupIndex, i, j);
        required(seg, 'text', 'group_preview_segment_missing_text', groupIndex, i, j);
        for (const key of ['text', 'color', 'bg']) {
          if (has(seg, key) && typeof seg[key] !== 'string') {
            invalid('group_preview_segment_invalid_' + key, groupIndex, i, j);
          }
        }
        keys(seg, ['text', 'color', 'bg'], 'group_preview_segment_unknown_key', groupIndex, i, j);
      });
    });
  }

  const groups = array(manifest.groups, 'groups_not_array');
  if (!groups.length) invalid('empty_groups');
  const groupNames = new Set();
  const groupKeys = schema === 1 ? ['name', 'description'] : ['name', 'description', 'kind', 'brew', 'preview'];
  groups.forEach((group, i) => {
    record(group, 'group_not_object', i);
    required(group, 'name', 'group_missing_name', i);
    required(group, 'description', 'group_missing_description', i);
    const name = token(group.name, 'group_invalid_name', i, schema === 1 ? legacyName : asciiToken);
    if (name === '.' || name === '..') invalid('group_invalid_name', name);
    if (schema === 2) {
      if (has(group, 'kind') && group.kind !== 'prompt') invalid('group_invalid_kind', i);
      if (has(group, 'brew')) {
        for (const dep of array(group.brew, 'group_invalid_brew', i)) {
          if (typeof dep !== 'string' || !asciiToken.test(dep)) invalid('group_invalid_brew', i);
          tables['group_brew_deps.tsv'].push([name, dep]);
        }
      }
      if (has(group, 'preview')) preview(group.preview, i);
    }
    keys(group, groupKeys, 'group_unknown_key', i);
    unique(groupNames, name, 'group_duplicate_name');
    localized(group.description, 'description', i);
    tables['groups.tsv'].push([name, group.description.en, group.description['zh-TW']]);
  });

  if (has(manifest, 'profiles')) {
    const profiles = record(manifest.profiles, 'profiles_not_object');
    for (const name of Object.keys(profiles)) {
      if (!legacyName.test(name)) invalid('profile_invalid_name', name);
      const members = array(profiles[name], 'profile_not_array', name);
      if (!members.length) invalid('profile_empty', name);
      const seen = new Set();
      members.forEach((member, j) => {
        if (typeof member !== 'string') invalid('profile_unknown_group', name, j);
        if (!groupNames.has(member)) invalid('profile_unknown_group', name, member);
        if (seen.has(member)) invalid('profile_duplicate_group', name, member);
        seen.add(member);
      });
    }
  }

  if (has(manifest, 'fonts')) {
    const fontCasks = new Set();
    array(manifest.fonts, 'fonts_not_array').forEach((font, i) => {
      record(font, 'font_not_object', i);
      const cask = token(required(font, 'cask', 'font_missing_cask', i), 'font_invalid_cask', i);
      unique(fontCasks, cask, 'font_duplicate_cask');
      if (has(font, 'preview') && typeof font.preview !== 'string') invalid('font_invalid_preview', i);
      const family = required(font, 'family', 'font_missing_family', i);
      fieldText(family, 'font_empty_family', 'font_control_char', i);
      localized(required(font, 'description', 'font_missing_description', i), 'description', i);
      keys(font, ['cask', 'family', 'description', 'preview'], 'font_unknown_key', i);
      tables['fonts.tsv'].push([cask, family]);
    });
  }

  const brewNames = new Set();
  if (has(manifest, 'brew')) {
    array(manifest.brew, 'brew_not_array').forEach((item, i) => {
      record(item, 'brew_not_object', i);
      const name = token(required(item, 'name', 'brew_missing_name', i), 'brew_invalid_name', i);
      unique(brewNames, name, 'brew_duplicate_name');
      const cask = flag(item, 'cask', 'brew_invalid_cask', i);
      if (has(item, 'tap')) {
        const tap = record(item.tap, 'brew_invalid_tap', i);
        const tapName = required(tap, 'name', 'brew_invalid_tap', i);
        if (typeof tapName !== 'string' || tapName.includes('..') ||
            !/^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*$/.test(tapName)) {
          invalid('brew_invalid_tap', i);
        }
        const trusted = flag(tap, 'trusted', 'brew_invalid_tap', i);
        keys(tap, ['name', 'trusted'], 'brew_invalid_tap', i);
        tables['brew_taps.tsv'].push([name, tapName, trusted]);
      }
      localized(required(item, 'description', 'brew_missing_description', i), 'description', i);
      keys(item, ['name', 'description', 'cask', 'tap'], 'brew_unknown_key', i);
      tables['brew.tsv'].push([name, cask]);
    });
  }
  for (const [group, dep] of tables['group_brew_deps.tsv']) {
    if (!brewNames.has(dep)) invalid('group_unknown_brew', group, dep);
  }

  function featureBrew(items, owner) {
    array(items, 'feature_brew_not_array', owner).forEach((item, i) => {
      record(item, 'feature_brew_not_object', owner, i);
      const name = required(item, 'name', 'feature_brew_missing_name', owner, i);
      if (typeof name !== 'string') invalid('feature_brew_invalid_name', owner, i);
      if (!asciiToken.test(name)) invalid('feature_brew_invalid_name', owner, name);
      const cask = flag(item, 'cask', 'feature_brew_invalid_cask', owner, i);
      keys(item, ['name', 'cask'], 'feature_brew_unknown_key', owner, i);
      tables['feature_brew.tsv'].push([owner, name, cask]);
    });
  }
  function copyPath(item, key, owner, i) {
    const path = required(item, key, 'feature_copy_missing_' + key, owner, i);
    const reason = 'feature_copy_invalid_' + key;
    if (typeof path !== 'string') invalid(reason, owner, i);
    if (!path || control.test(path) || path[0] === '/' || path.split('/').includes('..')) {
      invalid(reason, owner, path || '<empty>');
    }
    return path;
  }
  function featureCopies(items, owner) {
    array(items, 'feature_copy_not_array', owner).forEach((item, i) => {
      record(item, 'feature_copy_not_object', owner, i);
      const from = copyPath(item, 'from', owner, i);
      if (!isCheckoutFile(from)) invalid('feature_copy_invalid_from', owner, from);
      const to = copyPath(item, 'to', owner, i);
      keys(item, ['from', 'to'], 'feature_copy_unknown_key', owner, i);
      tables['feature_copy.tsv'].push([owner, from, to]);
    });
  }
  function featureHotkeys(items, owner, rawItems) {
    array(items, 'feature_hotkeys_not_array', owner).forEach((item, i) => {
      record(item, 'feature_hotkey_not_object', owner, i);
      const raw = rawItems && rawItems[i];
      const id = integer(required(item, 'id', 'feature_hotkey_missing_id', owner, i), raw && raw.id);
      if (id === null || id < 0) invalid('feature_hotkey_invalid_id', owner, i);
      required(item, 'enabled', 'feature_hotkey_invalid_enabled', owner, i);
      const enabled = flag(item, 'enabled', 'feature_hotkey_invalid_enabled', owner, i);
      const row = [owner, id, enabled];
      for (const key of ['ascii', 'keycode', 'modifiers']) {
        const param = has(item, key) ? integer(item[key], raw && raw[key]) : '';
        if (param === null) invalid('feature_hotkey_invalid_param', owner, i, key);
        row.push(param);
      }
      if (enabled && row.includes('')) invalid('feature_hotkey_missing_params', owner, i);
      keys(item, ['id', 'enabled', 'ascii', 'keycode', 'modifiers'], 'feature_hotkey_unknown_key', owner, i);
      tables['feature_hotkeys.tsv'].push(row);
    });
  }

  if (has(manifest, 'features')) {
    const featureNames = new Set();
    array(manifest.features, 'features_not_array').forEach((feature, i) => {
      record(feature, 'feature_not_object', i);
      const name = token(required(feature, 'name', 'feature_missing_name', i), 'feature_invalid_name', i);
      unique(featureNames, name, 'feature_duplicate_name');
      const macos = flag(feature, 'macos', 'feature_invalid_macos', name);
      const desc = required(feature, 'description', 'feature_missing_description', name);
      localized(desc, 'description', name);
      if (has(feature, 'notes')) {
        localized(feature.notes, 'notes', name);
        tables['feature_notes.tsv'].push([name, feature.notes.en, feature.notes['zh-TW']]);
      }
      if (has(feature, 'brew')) featureBrew(feature.brew, name);
      if (has(feature, 'copy')) featureCopies(feature.copy, name);
      if (has(feature, 'hotkeys')) featureHotkeys(feature.hotkeys, name, spellings && spellings.features[i].hotkeys);
      keys(feature, ['name', 'description', 'macos', 'notes', 'brew', 'copy', 'hotkeys'], 'feature_unknown_key', name);
      tables['features.tsv'].push([name, macos, desc.en, desc['zh-TW']]);
    });
  }

  // Never pass an unvalidated path component into the filesystem adapter.
  for (const name of groupNames) {
    if (!isPackageDirectory(name)) invalid('missing_package_dir', name);
  }
  return manifest;
}
