// macOS adapter. Only this file uses JXA; manifest and selection rules are plain JS.
class PlanError extends Error {
  constructor(key, args) {
    super(key);
    this.fields = [key, ...args];
  }
}

function fail(key, ...args) {
  throw new PlanError(key, args);
}

function run(argv) {
  ObjC.import('Foundation');
  const [manifestPath, checkout, sandbox, mode, value, language, tty, fzf] = argv;
  const files = $.NSFileManager.defaultManager;
  const canceled = {};

  function readText(path) {
    const text = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null);
    return ObjC.unwrap(text);
  }

  function writeText(name, text) {
    if (!$(text).writeToFileAtomicallyEncodingError($(sandbox + '/' + name), true, $.NSUTF8StringEncoding, null)) {
      throw new Error('Could not write ' + name);
    }
  }

  function isPackageDirectory(name) {
    // Inspect the last path component itself, not the target of a symbolic link.
    const attrs = files.attributesOfItemAtPathError($(checkout + '/' + name), null);
    return !attrs.isNil() && ObjC.unwrap(attrs.objectForKey($.NSFileType)) === ObjC.unwrap($.NSFileTypeDirectory);
  }

  function isCheckoutFile(path) {
    const resolved = $(checkout + '/' + path).stringByResolvingSymlinksInPath;
    const attrs = files.attributesOfItemAtPathError(resolved, null);
    return !attrs.isNil() && ObjC.unwrap(attrs.objectForKey($.NSFileType)) === ObjC.unwrap($.NSFileTypeRegular);
  }

  function choose(candidates) {
    if (tty !== '1') fail('no_tty');
    writeText('fzf_candidates.txt', candidates.join('\n') + '\n');
    writeText('fzf_output.txt', '');
    const input = $.NSFileHandle.fileHandleForReadingAtPath($(sandbox + '/fzf_candidates.txt'));
    const output = $.NSFileHandle.fileHandleForWritingAtPath($(sandbox + '/fzf_output.txt'));
    const task = $.NSTask.alloc.init;
    task.launchPath = $(fzf);
    task.arguments = $(['--multi', '--with-nth=1,2']);
    task.standardInput = input;
    task.standardOutput = output;
    try {
      if (!task.launchAndReturnError(null)) fail('fzf_failed', 127);
      task.waitUntilExit;
    } finally {
      input.closeFile;
      output.closeFile;
    }
    if (task.terminationStatus === 130) throw canceled;
    if (task.terminationStatus !== 0) fail('fzf_failed', task.terminationStatus);
    const text = readText(sandbox + '/fzf_output.txt');
    if (typeof text !== 'string') fail('fzf_failed', 'invalid output');
    if (text === '') return [];
    const lines = text.split('\n');
    if (lines[lines.length - 1] === '') lines.pop();
    return lines;
  }

  try {
    const tables = Object.create(null);
    const text = readText(manifestPath);
    if (typeof text !== 'string') fail('invalid_manifest', 'malformed_syntax');
    const manifest = parseManifest(text, isPackageDirectory, tables, isCheckoutFile);
    const {selected, unselected} = resolveSelection(manifest, mode, value, language, choose);
    for (const name of Object.keys(tables)) {
      writeText(name, tables[name].map(row => row.join('\t') + '\n').join(''));
    }
    writeText('selected.txt', selected.length ? selected.join('\n') + '\n' : '');
    writeText('unselected.txt', unselected.length ? unselected.join('\n') + '\n' : '');
    return 'ok';
  } catch (error) {
    if (error === canceled) return 'cancel';
    if (!(error instanceof PlanError)) throw error;
    // NUL-delimited arguments are read as data by Bash, never as shell code.
    writeText('plan.error', error.fields.map(field => String(field).replace(/\0/g, '\\0') + '\0').join(''));
    return 'error';
  }
}
