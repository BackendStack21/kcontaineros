//! A deliberately small shell: enough for Dockerfile `RUN`/`CMD` shell form,
//! entrypoint scripts and `docker exec -it ... sh`.
//!
//! Supported: quoting (`'`, `"`, `\`), `$VAR` `${VAR}` `${VAR:-default}` `$?`
//! `$$` `$#` `$@` `$*` `$0..$9`, pipelines, `&&` `||` `;` `&`, redirections
//! (`<` `>` `>>` `N>&M`), `VAR=value` prefixes, comments, and the builtins
//! `cd exit export unset exec set shift wait :`.
//!
//! Not supported: `if`/`for`/`while`/`case`, functions, globbing, `~`,
//! `$(...)`, here-documents. All of them are syntax errors rather than
//! being run as something else, and a script given with `-c` or as a file
//! is checked from start to end before its first command runs.
//!
//! Every variable is exported. Each pipeline is parsed and expanded right
//! before it runs, so there is no AST to keep around. The last command of a
//! `-c` string or script file replaces the shell (as with `exec`), so that
//! signals sent to the shell's PID reach the program it started.

use crate::util::{cz, eprint, errstr, exit_code, getenv, parse_u64, read_file, write_all};
use crate::{applets, sys, util};
use alloc::vec;
use alloc::vec::Vec;

type Bytes = Vec<u8>;
type PResult<T> = Result<T, &'static [u8]>;

struct Redir {
    fd: i32,
    /// `<` read, `>` truncate, `a` append, `d` duplicate (`N>&M`)
    kind: u8,
    /// None when the word expanded to nothing (`> $UNSET`)
    target: Option<Bytes>,
}

#[derive(Default)]
struct Cmd {
    argv: Vec<Bytes>,
    /// `NAME=value` prefixes
    assigns: Vec<Bytes>,
    redirs: Vec<Redir>,
    /// Something was written here, even if it expanded to nothing (`$UNSET`).
    seen: bool,
    /// How many words (not assignments or redirections) were written.
    words: usize,
    /// The command is `export`, written as such.
    export: bool,
    /// The command is `set`, written as such, and its options are not over.
    set: bool,
}

/// What terminated a pipeline.
#[derive(PartialEq, Clone, Copy)]
enum Sep {
    Seq,
    And,
    Or,
    Background,
    End,
}

/// The fields produced by expanding one word.
#[derive(Default)]
struct Word {
    fields: Vec<Bytes>,
    cur: Bytes,
    /// `cur` is a field even if empty (e.g. `""`)
    has: bool,
    /// saw a quoted `"$@"` with no positional parameters
    empty_at: bool,
    /// An assignment value or a redirection target: expansions are never
    /// split into fields.
    nosplit: bool,
    /// Assignments earlier in the same command, which a later value sees.
    overlay: Vec<Bytes>,
    /// How many `${NAME:-default}` enclose this word.
    depth: usize,
    /// The value of an assignment, where `~` also counts after `=` and `:`.
    assign: bool,
}

impl Word {
    fn end_field(&mut self) {
        if self.has {
            self.fields.push(core::mem::take(&mut self.cur));
            self.has = false;
        }
    }

    /// Append an unquoted expansion, splitting it on whitespace.
    fn split(&mut self, v: &[u8]) {
        for &c in v {
            if c.is_ascii_whitespace() {
                self.end_field();
            } else {
                self.cur.push(c);
                self.has = true;
            }
        }
    }

    fn finish(mut self) -> Vec<Bytes> {
        if self.has {
            self.fields.push(self.cur);
        }
        self.fields
    }
}

enum Value {
    One(Bytes),
    Many(Vec<Bytes>),
}

struct Shell {
    env: Vec<Bytes>,
    /// `$0`, `$1`, ...
    args: Vec<Bytes>,
    last: i32,
    opt_e: bool,
    opt_x: bool,
    interactive: bool,
    /// Running a `-c` string or a script file, as opposed to stdin.
    script: bool,
    /// `$!`: the last background process, 0 if there was none.
    bg: isize,
    /// Background processes this shell started and has not reaped yet.
    jobs: Vec<isize>,
    /// The exit status of those it has reaped, for `wait PID`.
    done: Vec<(isize, i32)>,
}

/// Words that start a compound command in POSIX sh. None are implemented,
/// and running their bodies as plain commands would be dangerous.
const RESERVED: &[&[u8]] = &[
    b"if", b"then", b"else", b"elif", b"fi", b"for", b"while", b"until", b"do", b"done", b"case",
    b"esac", b"function", b"select", b"{", b"}", b"!", b"[[",
];

/// Syntax errors that more input could fix. Reading from stdin, the shell
/// keeps reading lines while it gets one of these, so a quoted string that
/// spans lines stays one string.
/// Builtins of POSIX sh that cannot be an external program and are not
/// implemented. Looking them up on `$PATH` and carrying on would run the
/// rest of the script without what they were meant to set up.
const UNSUPPORTED: &[&[u8]] = &[
    b".", b"source", b"eval", b"trap", b"read", b"readonly", b"return", b"break", b"continue",
    b"local", b"alias", b"unalias", b"getopts", b"ulimit", b"fg", b"bg", b"jobs", b"hash", b"times",
    b"type",
];
const NO_BUILTIN: &[u8] =
    b"trap, eval, read, `.', return, local and similar builtins are not supported";

const OPEN_SINGLE: &[u8] = b"unterminated single quote";
const OPEN_DOUBLE: &[u8] = b"unterminated double quote";
const OPEN_BRACE: &[u8] = b"unterminated ${";
const OPEN_PIPE: &[u8] = b"unexpected end of input after `|'";
const OPEN_LIST: &[u8] = b"unexpected end of input after `&&' or `||'";
const OPEN_BACKSLASH: &[u8] = b"unexpected end of input after `\\'";
const UNFINISHED: &[&[u8]] =
    &[OPEN_SINGLE, OPEN_DOUBLE, OPEN_BRACE, OPEN_PIPE, OPEN_LIST, OPEN_BACKSLASH];

const SIGTSTP: usize = 20;
const SIGTTIN: usize = 21;
const SIGTTOU: usize = 22;

/// Highest file descriptor number accepted in a redirection.
const MAX_FD: u64 = 1023;

pub fn main(args: Vec<Bytes>, env: Vec<Bytes>) -> i32 {
    let mut sh = Shell {
        env,
        args: vec![b"sh".to_vec()],
        last: 0,
        opt_e: false,
        opt_x: false,
        interactive: false,
        script: false,
        bg: 0,
        jobs: Vec::new(),
        done: Vec::new(),
    };

    // PWD is where the shell is, whatever the environment claimed.
    let mut cwd = [0u8; 4096];
    let n = sys::getcwd(&mut cwd);
    if n > 1 {
        sh.setenv(&[b"PWD=", &cwd[..n as usize - 1]].concat());
    }

    let mut i = 1;
    let mut command: Option<&Bytes> = None;
    let mut want_command = false;
    while i < args.len() {
        let a = &args[i][..];
        if a == b"--" || a == b"-" {
            i += 1;
            break;
        }
        if a.len() < 2 || (a[0] != b'-' && a[0] != b'+') {
            break;
        }
        // `-c` may be part of a cluster: `sh -ec 'commands'`.
        let has_c = a[0] == b'-' && a[1..].contains(&b'c');
        let flags: Bytes = a.iter().copied().filter(|&f| f != b'c' || !has_c).collect();
        if flags.len() > 1 && !sh.set_flags(&flags) {
            return 2;
        }
        i += 1;
        want_command |= has_c;
    }
    // With -c the first operand is the command, whatever options follow -c.
    if want_command {
        if i >= args.len() {
            eprint(&[b"sh: -c requires an argument\n"]);
            return 2;
        }
        command = Some(&args[i]);
        i += 1;
    }

    sh.script = true;
    if let Some(c) = command {
        if i < args.len() {
            sh.args = args[i..].to_vec();
        }
        return sh.run(c);
    }
    if i < args.len() {
        let src = match read_file(&args[i]) {
            Ok(s) => s,
            Err(e) => {
                eprint(&[b"sh: ", &args[i], b": ", errstr(e), b"\n"]);
                return 127;
            }
        };
        sh.args = args[i..].to_vec();
        return sh.run(&src);
    }

    // Commands from stdin, with a prompt when it is a terminal.
    sh.script = false;
    sh.interactive = sys::isatty(0);
    if sh.interactive {
        sys::signal(sys::SIGINT, 1);
        sys::signal(sys::SIGQUIT, 1);
        // There is no job control, so nothing could ever resume a stopped
        // job: Ctrl-Z must not stop the shell or what it runs.
        for sig in [SIGTSTP, SIGTTIN, SIGTTOU] {
            sys::signal(sig, 1);
        }
    }
    loop {
        if sh.interactive {
            sh.prompt();
        }
        let Some(mut input) = read_line() else { break };
        // A line that ends inside a quote is not finished yet.
        'more: while let Some(open) = sh.unfinished(&input) {
            let quote = match open {
                OPEN_SINGLE => Some(b'\''),
                OPEN_DOUBLE => Some(b'"'),
                _ => None,
            };
            loop {
                if sh.interactive {
                    eprint(&[b"> "]);
                }
                let Some(more) = read_line() else { break 'more };
                input.push(b'\n');
                input.extend_from_slice(&more);
                // Only a line with the closing quote can end an open string:
                // checking the others again would make long strings quadratic.
                if !quote.is_some_and(|q| !more.contains(&q)) {
                    break;
                }
            }
        }
        // A script on stdin stops at its first syntax error: carrying on
        // would run lines that were meant to be guarded by the broken one.
        if !sh.syntax_ok(&input) {
            if !sh.interactive {
                return 2;
            }
            continue;
        }
        sh.execute(&input);
    }
    if sh.interactive {
        write_all(2, b"\n");
    }
    sh.last
}

/// Give a background command an empty stdin, as POSIX asks of a shell
/// without job control: it must not eat the script or the terminal's input.
fn null_stdin() {
    let fd = sys::open(b"/dev/null\0".as_ptr(), sys::O_RDONLY, 0);
    if fd > 0 {
        sys::dup3(fd as i32, 0);
        sys::close(fd as i32);
    } else if fd < 0 {
        sys::close(0);
    }
}

/// Read one line from stdin, a byte at a time so that nothing meant for a
/// child process is consumed.
fn read_line() -> Option<Bytes> {
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        let n = sys::read(0, &mut b);
        if n <= 0 {
            return if line.is_empty() { None } else { Some(line) };
        }
        if b[0] == b'\n' {
            return Some(line);
        }
        line.push(b[0]);
    }
}

fn wait_for(pid: isize) -> i32 {
    let mut st = 0;
    sys::wait4(pid, &mut st, 0);
    exit_code(st)
}

/// A pipe whose ends are never descriptors 0 to 2. When the shell itself
/// runs with stdin or stdout closed the kernel would hand those numbers
/// out, and a command could end up reading its own output.
fn make_pipe() -> Result<[i32; 2], isize> {
    let mut ends = [-1; 2];
    let e = sys::pipe(&mut ends);
    if e < 0 {
        return Err(e);
    }
    for k in 0..2 {
        if ends[k] < 3 {
            let moved = sys::dup_above(ends[k], 10);
            sys::close(ends[k]);
            if moved < 0 {
                sys::close(ends[1 - k]);
                return Err(moved);
            }
            ends[k] = moved as i32;
        }
    }
    Ok(ends)
}

fn is_name_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

fn is_blank(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r'
}

/// The length of a line continuation at the start of `s`: a backslash and
/// a newline, or with a carriage return between them in a CRLF script.
fn continuation(s: &[u8]) -> usize {
    if s.starts_with(b"\\\n") {
        2
    } else if s.starts_with(b"\\\r\n") {
        3
    } else {
        0
    }
}

fn skip_blanks(s: &[u8], i: &mut usize) {
    while *i < s.len() {
        if is_blank(s[*i]) {
            *i += 1;
        } else if continuation(&s[*i..]) > 0 {
            *i += continuation(&s[*i..]);
        } else {
            break;
        }
    }
}

/// True if the start of the file at `path` reads as text: no NUL byte,
/// which every binary has there and no script does.
fn is_script(path: &[u8]) -> bool {
    let fd = sys::open(cz(path).as_ptr(), sys::O_RDONLY, 0);
    if fd < 0 {
        return false;
    }
    let mut head = [0u8; 512];
    let n = sys::read(fd as i32, &mut head);
    sys::close(fd as i32);
    n >= 0 && !head[..n as usize].contains(&0)
}

fn is_builtin(name: &[u8]) -> bool {
    matches!(
        name,
        b":" | b"cd"
            | b"exit"
            | b"export"
            | b"unset"
            | b"exec"
            | b"set"
            | b"shift"
            | b"wait"
            | b"umask"
            | b"command"
    )
}

fn apply_redirs(redirs: &[Redir]) -> bool {
    for r in redirs {
        let Some(target) = &r.target else {
            eprint(&[b"sh: ambiguous redirect: the target is empty\n"]);
            return false;
        };
        if r.kind == b'd' {
            if &target[..] == b"-" {
                sys::close(r.fd);
                continue;
            }
            let Some(src) = parse_u64(target).filter(|&n| n <= MAX_FD) else {
                eprint(&[b"sh: ", target, b": bad file descriptor\n"]);
                return false;
            };
            if src as i32 != r.fd {
                let e = sys::dup3(src as i32, r.fd);
                if e < 0 {
                    eprint(&[b"sh: ", target, b": ", errstr(e), b"\n"]);
                    return false;
                }
            }
            continue;
        }
        let flags = match r.kind {
            b'<' => sys::O_RDONLY,
            b'>' => sys::O_WRONLY | sys::O_CREAT | sys::O_TRUNC,
            _ => sys::O_WRONLY | sys::O_CREAT | sys::O_APPEND,
        };
        let fd = sys::open(cz(target).as_ptr(), flags, 0o666);
        if fd < 0 {
            eprint(&[b"sh: ", target, b": ", errstr(fd), b"\n"]);
            return false;
        }
        if fd as i32 != r.fd {
            let e = sys::dup3(fd as i32, r.fd);
            sys::close(fd as i32);
            if e < 0 {
                eprint(&[b"sh: ", target, b": ", errstr(e), b"\n"]);
                return false;
            }
        }
    }
    true
}

impl Shell {
    fn prompt(&self) {
        let mut buf = [0u8; 1024];
        let n = sys::getcwd(&mut buf);
        let cwd: &[u8] = if n > 1 { &buf[..n as usize - 1] } else { b"?" };
        let sigil: &[u8] = if sys::getuid() == 0 { b" # " } else { b" $ " };
        eprint(&[cwd, sigil]);
    }

    /// Apply `-ex` / `+ex` style option flags.
    fn set_flags(&mut self, a: &[u8]) -> bool {
        // All of it or none: `-ue` must not leave `-e` off and carry on.
        if a[1..].iter().any(|f| !matches!(f, b'e' | b'x')) {
            eprint(&[b"sh: unsupported option: ", a, b" (only -e and -x)\n"]);
            return false;
        }
        let on = a[0] == b'-';
        for &f in &a[1..] {
            match f {
                b'e' => self.opt_e = on,
                _ => self.opt_x = on,
            }
        }
        true
    }

    /// A special builtin was used in a way this shell does not implement:
    /// a script ends there, as POSIX has it, instead of running on without
    /// what the builtin was meant to do.
    fn misuse(&self) -> i32 {
        if !self.interactive {
            sys::exit(2);
        }
        2
    }

    /// Collect background processes that have ended, keeping the status of
    /// those this shell started for `wait PID`.
    fn reap_background(&mut self) {
        let mut st = 0;
        loop {
            let pid = sys::wait4(-1, &mut st, sys::WNOHANG);
            if pid <= 0 {
                return;
            }
            self.reaped(pid, st);
        }
    }

    fn reaped(&mut self, pid: isize, status: i32) {
        if let Some(k) = self.jobs.iter().position(|&j| j == pid) {
            self.jobs.swap_remove(k);
            self.done.push((pid, exit_code(status)));
        }
    }

    /// Remember a background process just started.
    fn started(&mut self, pid: isize) {
        // The number may have belonged to an earlier job.
        self.done.retain(|d| d.0 != pid);
        self.jobs.push(pid);
        self.bg = pid;
    }

    /// Wait for the child `pid` (-1: any) to end. At a prompt Ctrl-C ends
    /// the wait, which gives None; the shell ignores SIGINT there, so it is
    /// taken as a pending signal instead.
    fn wait_child(&mut self, pid: isize) -> Option<(isize, i32)> {
        let mut st = 0;
        if !self.interactive {
            let got = sys::wait4(pid, &mut st, 0);
            return Some((got, st));
        }
        let set: u64 = 1 << (sys::SIGINT - 1) | 1 << (sys::SIGCHLD - 1);
        let mut old: u64 = 0;
        sys::sigblock(&set, &mut old);
        sys::signal(sys::SIGINT, 0);
        let result = loop {
            let got = sys::wait4(pid, &mut st, sys::WNOHANG);
            if got != 0 {
                break Some((got, st));
            }
            if sys::sigwait(&set, None) == sys::SIGINT as isize {
                break None;
            }
        };
        sys::signal(sys::SIGINT, 1);
        sys::sigsetmask(&old, None);
        result
    }

    fn setenv(&mut self, kv: &[u8]) {
        let klen = kv.iter().position(|&c| c == b'=').map_or(kv.len(), |p| p + 1);
        match self.env.iter_mut().find(|e| e.starts_with(&kv[..klen])) {
            Some(e) => *e = kv.to_vec(),
            None => self.env.push(kv.to_vec()),
        }
    }

    // ---- execution -------------------------------------------------------

    /// Run a whole script; returns the status of the last command.
    fn run(&mut self, src: &[u8]) -> i32 {
        // Find every syntax error before anything has run.
        if !self.syntax_ok(src) {
            return 2;
        }
        self.execute(src)
    }

    fn syntax_ok(&mut self, src: &[u8]) -> bool {
        if let Err(msg) = self.check(src) {
            eprint(&[b"sh: syntax error: ", msg, b"\n"]);
            self.last = 2;
            return false;
        }
        true
    }

    /// Run `src`, which has passed `check`.
    fn execute(&mut self, src: &[u8]) -> i32 {
        let mut i = 0;
        let mut go = true;
        let mut list_start = true;
        loop {
            self.reap_background();
            // `a && b &` puts the whole list in the background, not just `b`.
            let background = if list_start { self.background_list(src, i) } else { None };
            if let Some(end) = background {
                let pid = sys::fork();
                if pid == 0 {
                    null_stdin();
                    sys::signal(sys::SIGINT, 1);
                    sys::signal(sys::SIGQUIT, 1);
                    self.interactive = false;
                    let code = self.execute(&src[i..end - 1]);
                    sys::exit(code);
                }
                if pid < 0 {
                    eprint(&[b"sh: fork: ", errstr(pid), b"\n"]);
                    self.last = 1;
                    if self.opt_e {
                        sys::exit(1);
                    }
                } else {
                    self.started(pid);
                    self.last = 0;
                }
                i = end;
                continue;
            }
            // (It parsed when it was checked, and parses the same way now.)
            let Ok((cmds, sep)) = self.parse_pipeline(src, &mut i) else { return 2 };
            if !cmds.is_empty() && go {
                if self.is_final(&cmds, sep, &src[i..]) {
                    self.trace(&cmds);
                    self.run_child(&cmds[0]);
                }
                self.last = self.exec_pipeline(&cmds, sep == Sep::Background);
                if self.opt_e && self.last != 0 && sep != Sep::And && sep != Sep::Or {
                    sys::exit(self.last);
                }
            }
            // A skipped pipeline leaves `last` untouched, which gives the
            // usual left-associative `a && b || c` behaviour.
            list_start = sep != Sep::And && sep != Sep::Or;
            go = match sep {
                Sep::End => return self.last,
                Sep::And => self.last == 0,
                Sep::Or => self.last != 0,
                _ => true,
            };
        }
    }

    /// If an and-or list of several pipelines starts at `i` and ends in `&`,
    /// the position just after that `&`.
    fn background_list(&self, src: &[u8], i: usize) -> Option<usize> {
        let mut j = i;
        let mut pipelines = 0;
        loop {
            let (_, sep) = self.parse_pipeline(src, &mut j).ok()?;
            pipelines += 1;
            match sep {
                Sep::And | Sep::Or => continue,
                Sep::Background if pipelines > 1 => return Some(j),
                _ => return None,
            }
        }
    }

    /// Parse the whole of `src` without running anything.
    fn check(&self, src: &[u8]) -> PResult<()> {
        if src.contains(&0) {
            return Err(b"NUL byte in the script");
        }
        let mut i = 0;
        while self.parse_pipeline(src, &mut i)?.1 != Sep::End {}
        Ok(())
    }

    /// True if `src` stops in the middle of a quote, `${`, a pipeline or an
    /// and-or list, or right after a backslash.
    fn unfinished(&self, src: &[u8]) -> Option<&'static [u8]> {
        self.check(src).err().filter(|e| UNFINISHED.contains(e))
    }

    /// True when `cmds` is one external command and nothing follows it in a
    /// script: the shell can then become that command instead of waiting
    /// for it.
    fn is_final(&self, cmds: &[Cmd], sep: Sep, rest: &[u8]) -> bool {
        let simple = cmds.len() == 1 && !cmds[0].argv.is_empty() && !is_builtin(&cmds[0].argv[0]);
        let ends = sep == Sep::End || (sep == Sep::Seq && only_blank(rest));
        self.script && simple && ends
    }

    fn trace(&self, cmds: &[Cmd]) {
        if !self.opt_x {
            return;
        }
        for c in cmds {
            let mut parts: Vec<&[u8]> = vec![b"+"];
            for a in c.assigns.iter().chain(c.argv.iter()) {
                parts.push(b" ");
                parts.push(a);
            }
            parts.push(b"\n");
            eprint(&parts);
        }
    }

    fn exec_pipeline(&mut self, cmds: &[Cmd], background: bool) -> i32 {
        self.trace(cmds);

        if cmds.len() == 1 && !background {
            let c = &cmds[0];
            if c.argv.is_empty() {
                for a in &c.assigns {
                    self.setenv(a);
                }
                if c.redirs.is_empty() {
                    return 0;
                }
            } else if is_builtin(&c.argv[0]) {
                // Assignments stay after a special builtin, as POSIX says,
                // and last only for the call of an ordinary one.
                let ordinary = matches!(&c.argv[0][..], b"cd" | b"wait" | b"umask" | b"command");
                let before = if ordinary && !c.assigns.is_empty() { Some(self.env.clone()) } else { None };
                for a in &c.assigns {
                    self.setenv(a);
                }
                let status = self.builtin_redirected(c);
                if let Some(mut env) = before {
                    core::mem::swap(&mut self.env, &mut env);
                    for key in [&b"PWD"[..], b"OLDPWD"] {
                        if let Some(v) = getenv(&env, key) {
                            self.setenv(&[key, b"=", v].concat());
                        }
                    }
                }
                return status;
            }
        }

        let mut pids = Vec::with_capacity(cmds.len());
        let mut prev_read = -1; // read end of the previous pipe, if any
        for (k, c) in cmds.iter().enumerate() {
            let last = k + 1 == cmds.len();
            let mut pfd = [-1i32; 2];
            if !last {
                match make_pipe() {
                    Ok(ends) => pfd = ends,
                    Err(e) => {
                        eprint(&[b"sh: pipe: ", errstr(e), b"\n"]);
                        break;
                    }
                }
            }
            let pid = sys::fork();
            if pid == 0 {
                if prev_read >= 0 {
                    sys::dup3(prev_read, 0);
                    sys::close(prev_read);
                } else if background {
                    null_stdin();
                }
                // Without job control a background command is not what
                // Ctrl-C is aimed at.
                if background {
                    sys::signal(sys::SIGINT, 1);
                    sys::signal(sys::SIGQUIT, 1);
                }
                if !last {
                    sys::close(pfd[0]);
                    sys::dup3(pfd[1], 1);
                    sys::close(pfd[1]);
                }
                // Ctrl-C is for the foreground command, not for a background one.
                if self.interactive && !background {
                    sys::signal(sys::SIGINT, 0);
                    sys::signal(sys::SIGQUIT, 0);
                }
                self.run_child(c);
            }
            if prev_read >= 0 {
                sys::close(prev_read);
                prev_read = -1;
            }
            if !last {
                sys::close(pfd[1]);
                prev_read = pfd[0];
            }
            if pid < 0 {
                eprint(&[b"sh: fork: ", errstr(pid), b"\n"]);
                break;
            }
            pids.push(pid);
        }
        if pids.len() != cmds.len() {
            if prev_read >= 0 {
                sys::close(prev_read);
            }
            for &p in &pids {
                wait_for(p);
            }
            return 1;
        }
        if background {
            for &p in &pids {
                self.started(p);
            }
            return 0;
        }
        let mut status = 0;
        for &p in &pids {
            status = wait_for(p);
        }
        status
    }

    /// Body of a forked child: never returns.
    fn run_child(&mut self, c: &Cmd) -> ! {
        if !apply_redirs(&c.redirs) {
            sys::exit(1);
        }
        for a in &c.assigns {
            self.setenv(a);
        }
        if c.argv.is_empty() {
            sys::exit(0);
        }
        if is_builtin(&c.argv[0]) {
            let st = self.builtin(c, true);
            sys::exit(st);
        }
        self.exec_or_die(&c.argv)
    }

    fn exec_or_die(&self, argv: &[Bytes]) -> ! {
        if UNSUPPORTED.contains(&&argv[0][..]) {
            eprint(&[b"sh: ", &argv[0], b": this builtin is not supported\n"]);
            sys::exit(2);
        }
        let mut found = Vec::new();
        let e = util::exec_found(argv, &self.env, &mut found);
        if e == sys::ENOENT && !argv[0].contains(&b'/') {
            // Not on $PATH: fall back to the built-in implementation, so the
            // binary keeps working even without its symlinks.
            if &argv[0][..] == b"sh" {
                sys::exit(main(argv.to_vec(), self.env.clone()));
            }
            if let Some(code) = applets::run(argv, &self.env) {
                sys::exit(code);
            }
            eprint(&[b"sh: ", &argv[0], b": not found\n"]);
            sys::exit(127);
        }
        if e == sys::ENOEXEC && is_script(&found) {
            // An executable text file without a `#!` line is a script for
            // this shell: start the shell again on exactly that file.
            let mut args = vec![b"sh".to_vec(), b"--".to_vec(), found];
            args.extend_from_slice(&argv[1..]);
            let argz: Vec<Bytes> = args.iter().map(|a| cz(a)).collect();
            let envz: Vec<Bytes> = self.env.iter().map(|e| cz(e)).collect();
            let mut argp: Vec<*const u8> = argz.iter().map(|a| a.as_ptr()).collect();
            let mut envp: Vec<*const u8> = envz.iter().map(|e| e.as_ptr()).collect();
            argp.push(core::ptr::null());
            envp.push(core::ptr::null());
            sys::execve(b"/proc/self/exe\0".as_ptr(), argp.as_ptr(), envp.as_ptr());
        }
        eprint(&[b"sh: ", &argv[0], b": ", errstr(e), b"\n"]);
        sys::exit(if e == sys::ENOENT || e == sys::ENOTDIR { 127 } else { 126 })
    }

    /// Run a builtin in the shell itself with its redirections in effect,
    /// then put the shell's own descriptors back. `exec` is the exception:
    /// its redirections are meant to stay.
    fn builtin_redirected(&mut self, c: &Cmd) -> i32 {
        if c.redirs.is_empty() || &c.argv[0][..] == b"exec" {
            return self.builtin(c, false);
        }
        // The copies go above every descriptor the command itself names, so
        // that no redirection can land on one of them.
        let named = |r: &Redir| {
            let source = r.target.as_deref().and_then(parse_u64).filter(|&n| n <= MAX_FD);
            r.fd.max(source.unwrap_or(0) as i32)
        };
        let floor = c.redirs.iter().map(named).max().unwrap_or(0).max(9) + 1;
        let mut saved: Vec<(i32, isize)> = Vec::new();
        let mut status = 0;
        for r in &c.redirs {
            let copy = sys::dup_above(r.fd, floor);
            if copy < 0 && copy != sys::EBADF {
                eprint(&[b"sh: cannot redirect: ", errstr(copy), b"\n"]);
                status = 1;
                break;
            }
            saved.push((r.fd, copy));
        }
        let mut redirected = true;
        if status == 0 {
            redirected = apply_redirs(&c.redirs);
            status = if redirected { self.builtin(c, false) } else { 1 };
        }
        // As POSIX has it, a redirection that fails on a special builtin
        // ends a script; `cd`, `wait` and `umask` are ordinary ones.
        let special = !matches!(&c.argv[0][..], b"cd" | b"wait" | b"umask" | b"command");
        if !redirected && special && !self.interactive {
            sys::exit(1);
        }
        for &(fd, copy) in saved.iter().rev() {
            if copy >= 0 {
                sys::dup3(copy as i32, fd);
                sys::close(copy as i32);
            } else {
                sys::close(fd); // it was closed before
            }
        }
        status
    }

    fn builtin(&mut self, c: &Cmd, in_child: bool) -> i32 {
        let a = &c.argv;
        match &a[0][..] {
            b"cd" => {
                // -P is how it works anyway; -L is taken for the same.
                let mut first = 1;
                while a.get(first).is_some_and(|arg| arg == b"-P" || arg == b"-L") {
                    first += 1;
                }
                first += a.get(first).is_some_and(|arg| arg == b"--") as usize;
                let dir = a.get(first).map(|d| &d[..]).or_else(|| getenv(&self.env, b"HOME")).unwrap_or(b"/");
                // `cd -`: back to where the last `cd` left, saying where.
                let back = dir == b"-";
                let dir = if back { getenv(&self.env, b"OLDPWD").unwrap_or(b"") } else { dir };
                if back && dir.is_empty() {
                    eprint(&[b"sh: cd: OLDPWD is not set\n"]);
                    return 1;
                }
                let dir = dir.to_vec();
                let dir = &dir[..];
                let mut buf = [0u8; 4096];
                let n = sys::getcwd(&mut buf);
                let old = if n > 1 { buf[..n as usize - 1].to_vec() } else { Vec::new() };
                let e = sys::chdir(cz(dir).as_ptr());
                if e < 0 {
                    eprint(&[b"sh: cd: ", dir, b": ", errstr(e), b"\n"]);
                    return 1;
                }
                let n = sys::getcwd(&mut buf);
                if n > 1 {
                    self.setenv(&[b"OLDPWD=", &old[..]].concat());
                    self.setenv(&[b"PWD=", &buf[..n as usize - 1]].concat());
                    if back {
                        write_all(1, &[&buf[..n as usize - 1], b"\n"].concat());
                    }
                }
                0
            }
            b"exit" => match a.get(1).map(|v| parse_u64(v)) {
                None => sys::exit(self.last),
                Some(Some(code)) => sys::exit((code & 0xff) as i32),
                Some(None) => {
                    eprint(&[b"sh: exit: ", &a[1], b": numeric argument required\n"]);
                    sys::exit(2)
                }
            },
            b"export" => {
                // Every variable is already exported; only NAME=value matters.
                let mut status = 0;
                let first = 1 + a.get(1).is_some_and(|arg| arg == b"--") as usize;
                if first == 1 && a.get(1).is_some_and(|arg| arg.starts_with(b"-")) {
                    eprint(&[b"sh: export: ", &a[1], b": options are not supported\n"]);
                    return self.misuse();
                }
                for kv in &a[first..] {
                    let name = kv.split(|&c| c == b'=').next().unwrap_or(b"");
                    let valid = name.first().is_some_and(|&c| is_name_start(c))
                        && name.iter().all(|&c| is_name_char(c))
                        && name != b"IFS";
                    if !valid {
                        eprint(&[b"sh: export: ", kv, b": bad variable name\n"]);
                        status = 1;
                    } else if kv.contains(&b'=') {
                        self.setenv(kv);
                    }
                }
                status
            }
            b"unset" => {
                // -v is what it does anyway; there are no functions for -f.
                let first = 1 + a.get(1).is_some_and(|arg| arg == b"-v") as usize;
                let dashes = a.get(first).is_some_and(|arg| arg == b"--");
                let first = first + dashes as usize;
                if !dashes && a.get(first).is_some_and(|arg| arg.starts_with(b"-")) {
                    eprint(&[b"sh: unset: ", &a[first], b": options are not supported\n"]);
                    return self.misuse();
                }
                for k in &a[first..] {
                    self.env.retain(|e| !(e.starts_with(k) && e.get(k.len()) == Some(&b'=')));
                }
                0
            }
            b"exec" => {
                if !in_child && !apply_redirs(&c.redirs) {
                    if self.interactive {
                        return 1;
                    }
                    sys::exit(1);
                }
                let a = &a[a.get(1).is_some_and(|arg| arg == b"--") as usize..];
                if a.len() == 1 {
                    return 0;
                }
                // The interactive shell ignores these; its replacement must not.
                if self.interactive {
                    sys::signal(sys::SIGINT, 0);
                    sys::signal(sys::SIGQUIT, 0);
                }
                self.exec_or_die(&a[1..])
            }
            b"set" => {
                // set [-ex] [+ex] [--] [ARG...]: options, then, if anything
                // follows them, new positional parameters.
                let mut k = 1;
                // (`--`, or a lone `-` or `+`, ends the options.)
                while k < a.len() && a[k].len() > 1 && matches!(a[k][0], b'-' | b'+') && a[k] != b"--" {
                    if !self.set_flags(&a[k]) {
                        return self.misuse();
                    }
                    k += 1;
                }
                let dashes = a.get(k).is_some_and(|arg| matches!(&arg[..], b"--" | b"-" | b"+"));
                // `set -` on its own changes nothing; `set --` clears.
                if (dashes && (a[k] == b"--" || k + 1 < a.len())) || (!dashes && k < a.len()) {
                    self.args.truncate(1);
                    self.args.extend_from_slice(&a[k + dashes as usize..]);
                }
                0
            }
            b"shift" => {
                let count = a.get(1).map_or(Some(1), |v| parse_u64(v));
                match count {
                    Some(n) if n < self.args.len() as u64 => {
                        self.args.drain(1..1 + n as usize);
                        0
                    }
                    Some(_) => {
                        eprint(&[b"sh: shift: cannot shift that many\n"]);
                        1
                    }
                    None => {
                        eprint(&[b"sh: shift: ", &a[1], b": not a number\n"]);
                        self.misuse()
                    }
                }
            }
            b"wait" => {
                if a.len() == 1 {
                    // For the jobs this shell started, not for whatever a
                    // shell running as PID 1 has adopted.
                    while !self.jobs.is_empty() {
                        match self.wait_child(-1) {
                            None => return 130,
                            Some((pid, _)) if pid <= 0 => break,
                            Some((pid, st)) => self.reaped(pid, st),
                        }
                    }
                    return 0;
                }
                if a[1].starts_with(b"-") {
                    eprint(&[b"sh: wait: ", &a[1], b": options are not supported\n"]);
                    return 2;
                }
                // wait PID...: the status of the last one, 127 if it is not
                // a child of this shell.
                let mut status = 0;
                for p in &a[1..] {
                    let Some(pid) = parse_u64(p).filter(|&n| n > 0 && n <= i32::MAX as u64) else {
                        eprint(&[b"sh: wait: ", p, b": not a process ID\n"]);
                        return 2;
                    };
                    let pid = pid as isize;
                    status = match self.done.iter().position(|d| d.0 == pid) {
                        Some(k) => self.done.remove(k).1,
                        None => match self.wait_child(pid) {
                            None => return 130,
                            Some((got, st)) if got == pid => {
                                self.jobs.retain(|&j| j != pid);
                                exit_code(st)
                            }
                            Some(_) => 127,
                        },
                    };
                }
                status
            }
            b"command" => {
                // command -v NAME: where NAME would be found. command NAME
                // ARGS: run it. There are no functions to bypass.
                if a.get(1).is_some_and(|arg| arg == b"-v") && a.len() > 2 {
                    let mut status = 0;
                    for name in &a[2..] {
                        let path = getenv(&self.env, b"PATH").unwrap_or(util::DEFAULT_PATH);
                        let runs = |file: &[u8]| sys::access_x(cz(file).as_ptr()) == 0 && !util::is_dir(file);
                        let found = if is_builtin(name) {
                            Some(name.clone())
                        } else if name.contains(&b'/') {
                            runs(name).then(|| name.clone())
                        } else {
                            path.split(|&c| c == b':')
                                .map(|dir| util::join(if dir.is_empty() { b"." } else { dir }, name))
                                .find(|file| runs(file))
                                // What runs without being on $PATH; see `exec_or_die`.
                                .or_else(|| {
                                    (name == b"sh" || applets::LIST.iter().any(|(n, _)| *n == &name[..]))
                                        .then(|| name.clone())
                                })
                        };
                        match found {
                            Some(mut line) => {
                                line.push(b'\n');
                                status |= !write_all(1, &line) as i32;
                            }
                            None => status = 1,
                        }
                    }
                    return status;
                }
                let first = 1 + a.get(1).is_some_and(|arg| arg == b"--") as usize;
                if a.len() <= first || a[first].starts_with(b"-") {
                    eprint(&[b"sh: command: only `command -v NAME' and `command NAME ARGS' are supported\n"]);
                    return 2;
                }
                let a = &a[first - 1..];
                // A builtin is run as one: `command cd DIR` has to change
                // this shell's directory.
                if is_builtin(&a[1]) {
                    let inner = Cmd { argv: a[1..].to_vec(), ..Cmd::default() };
                    return self.builtin(&inner, in_child);
                }
                if in_child {
                    self.exec_or_die(&a[1..]);
                }
                let pid = sys::fork();
                if pid == 0 {
                    if self.interactive {
                        sys::signal(sys::SIGINT, 0);
                        sys::signal(sys::SIGQUIT, 0);
                    }
                    self.exec_or_die(&a[1..]);
                }
                if pid < 0 {
                    eprint(&[b"sh: fork: ", errstr(pid), b"\n"]);
                    return 1;
                }
                wait_for(pid)
            }
            b"umask" => {
                let Some(spec) = a.get(1) else {
                    let mask = sys::umask(0o022);
                    sys::umask(mask as usize);
                    let digits = [b'0', b'0' + (mask >> 6 & 7) as u8, b'0' + (mask >> 3 & 7) as u8, b'0' + (mask & 7) as u8, b'\n'];
                    return !write_all(1, &digits) as i32;
                };
                if spec.is_empty() || spec.len() > 4 || spec.iter().any(|c| !(b'0'..=b'7').contains(c)) {
                    eprint(&[b"sh: umask: ", spec, b": only octal masks are supported\n"]);
                    return 2;
                }
                let mask = spec.iter().fold(0, |m, &c| m * 8 + (c - b'0') as usize);
                if mask > 0o777 {
                    eprint(&[b"sh: umask: ", spec, b": only octal masks are supported\n"]);
                    return 2;
                }
                sys::umask(mask);
                0
            }
            _ => 0, // ":"
        }
    }

    // ---- parsing ---------------------------------------------------------

    fn parse_pipeline(&self, s: &[u8], i: &mut usize) -> PResult<(Vec<Cmd>, Sep)> {
        let mut cmds = Vec::new();
        loop {
            let c = self.parse_command(s, i)?;
            // Decided by what was written, not by what it expands to: a
            // script must not be valid or invalid depending on a variable.
            let empty = !c.seen;
            if *i >= s.len() {
                if empty && !cmds.is_empty() {
                    return Err(OPEN_PIPE);
                }
                if !empty {
                    cmds.push(c);
                }
                return Ok((cmds, Sep::End));
            }
            let op = s[*i];
            let doubled = s.get(*i + 1) == Some(&op);
            if op == b'|' && !doubled {
                if empty {
                    return Err(b"unexpected `|'");
                }
                cmds.push(c);
                *i += 1;
                skip_newlines(s, i);
                continue;
            }
            if op == b'&' && s.get(*i + 1) == Some(&b'>') {
                return Err(b"`&>' is not supported; write `>file 2>&1'");
            }
            let sep = match (op, doubled) {
                (b'|', _) => Sep::Or,
                (b'&', true) => Sep::And,
                (b'&', false) => Sep::Background,
                _ => Sep::Seq, // newline or `;`
            };
            *i += if sep == Sep::Or || sep == Sep::And { 2 } else { 1 };
            if empty {
                if !cmds.is_empty() || sep != Sep::Seq {
                    return Err(b"unexpected operator");
                }
            } else {
                cmds.push(c);
            }
            if sep == Sep::Or || sep == Sep::And {
                // A command has to follow, possibly on a later line.
                skip_newlines(s, i);
                match s.get(*i) {
                    None => return Err(OPEN_LIST),
                    Some(b';' | b'&' | b'|') => return Err(b"unexpected operator"),
                    Some(_) => {}
                }
            }
            return Ok((cmds, sep));
        }
    }

    /// Parse one simple command; stops at (without consuming) an operator.
    fn parse_command(&self, s: &[u8], i: &mut usize) -> PResult<Cmd> {
        let mut cmd = Cmd::default();
        loop {
            skip_blanks(s, i);
            if *i >= s.len() {
                break;
            }
            let c = s[*i];
            if matches!(c, b'\n' | b';' | b'|' | b'&') {
                break;
            }
            if c == b'#' {
                while *i < s.len() && s[*i] != b'\n' {
                    *i += 1;
                }
                continue;
            }

            // Redirection, with an optional leading fd number: `2>file`.
            let mut j = *i;
            while j < s.len() && s[j].is_ascii_digit() {
                j += 1;
            }
            if j < s.len() && (s[j] == b'<' || s[j] == b'>') {
                let op = s[j];
                let fd = match parse_u64(&s[*i..j]) {
                    Some(n) if n <= MAX_FD => n as i32,
                    Some(_) => return Err(b"file descriptor out of range"),
                    None if j > *i => return Err(b"file descriptor out of range"),
                    None => (op == b'>') as i32,
                };
                j += 1;
                let mut kind = op;
                if s.get(j) == Some(&op) {
                    if op == b'<' {
                        return Err(b"here-documents are not supported");
                    }
                    kind = b'a';
                    j += 1;
                } else if s.get(j) == Some(&b'&') {
                    kind = b'd';
                    j += 1;
                }
                *i = j;
                skip_blanks(s, i);
                let start = *i;
                let words = self.parse_word(s, i, Word { nosplit: true, ..Word::default() })?;
                if *i == start {
                    return Err(b"missing redirection target");
                }
                // What it expands to is only known when the command runs.
                let target = words.into_iter().next();
                cmd.redirs.push(Redir { fd, kind, target });
                cmd.seen = true;
                continue;
            }

            // `NAME=value` before the command name.
            if cmd.words == 0 && is_name_start(c) {
                let mut k = *i;
                while k < s.len() && is_name_char(s[k]) {
                    k += 1;
                }
                if s.get(k) == Some(&b'=') {
                    if &s[*i..k] == b"IFS" {
                        return Err(b"IFS is not supported: fields are split on whitespace");
                    }
                    let mut kv = s[*i..=k].to_vec();
                    *i = k + 1;
                    let value = Word { nosplit: true, assign: true, overlay: cmd.assigns.clone(), ..Word::default() };
                    kv.extend(self.parse_word(s, i, value)?.into_iter().flatten());
                    cmd.assigns.push(kv);
                    cmd.seen = true;
                    continue;
                }
            }

            let start = *i;
            let command_name = cmd.words == 0;
            // `export NAME=$VALUE` assigns like `NAME=$VALUE` does: the
            // value is one field however many blanks it holds.
            let name_len = s[start..].iter().take_while(|&&c| is_name_char(c)).count();
            let assigns = cmd.export && is_name_start(c) && s.get(start + name_len) == Some(&b'=');
            let words = self.parse_word(s, i, Word { nosplit: assigns, assign: assigns, ..Word::default() })?;
            cmd.export |= command_name && &s[start..*i] == b"export";
            // `set -u`, `set -o pipefail`: known to be unsupported before
            // anything runs, when written out.
            let raw = &s[start..*i];
            if cmd.set && raw.len() > 1 && matches!(raw[0], b'-' | b'+') && raw != b"--" {
                // Only what is written out can be judged here.
                let literal = !raw.iter().any(|c| matches!(c, b'$' | b'"' | b'\'' | b'\\'));
                if literal && raw[1..].iter().any(|f| !matches!(f, b'e' | b'x')) {
                    return Err(b"set: only -e, -x and -- are supported");
                }
            } else if cmd.words > 0 {
                cmd.set = false; // past the options
            }
            cmd.set |= command_name && raw == b"set";
            if command_name && RESERVED.contains(&&s[start..*i]) {
                return Err(b"if, for, while, case, { } and ! are not supported");
            }
            if command_name && UNSUPPORTED.contains(&&s[start..*i]) {
                return Err(NO_BUILTIN);
            }
            cmd.words += 1;
            cmd.seen = true;
            cmd.argv.extend(words);
        }
        Ok(cmd)
    }

    /// Parse and expand one word into zero or more fields.
    /// `w` says how: `Word::default()` for an ordinary word.
    fn parse_word(&self, s: &[u8], i: &mut usize, mut w: Word) -> PResult<Vec<Bytes>> {
        let start = *i;
        while *i < s.len() {
            let c = s[*i];
            match c {
                b' ' | b'\t' | b'\r' | b'\n' | b';' | b'|' | b'&' | b'<' | b'>' => break,
                b'(' | b')' => return Err(b"subshells and functions are not supported"),
                b'*' | b'?' | b'[' => {
                    return Err(b"globbing is not supported; quote `*', `?' and `['")
                }
                // Where it is written, not what came before it expanded to.
                b'~' if *i == start || (w.assign && matches!(s[*i - 1], b':' | b'=')) =>
                {
                    return Err(b"`~' expansion is not supported; use $HOME or quote it")
                }
                b'`' => return Err(b"command substitution is not supported"),
                b'\'' => {
                    let start = *i + 1;
                    let len = s[start..]
                        .iter()
                        .position(|&c| c == b'\'')
                        .ok_or(OPEN_SINGLE)?;
                    w.cur.extend_from_slice(&s[start..start + len]);
                    w.has = true;
                    *i = start + len + 1;
                }
                b'"' => {
                    let (mut elements, mut empty_ats) = (0usize, 0usize);
                    *i += 1;
                    loop {
                        match s.get(*i) {
                            None => return Err(OPEN_DOUBLE),
                            Some(b'"') => {
                                *i += 1;
                                // Quotes make a field even when empty, except
                                // around nothing but a "$@" with no parameters.
                                w.has |= elements == 0 || empty_ats < elements;
                                break;
                            }
                            Some(b'\\') if matches!(s.get(*i + 1), Some(b'"' | b'$' | b'\\' | b'`')) => {
                                elements += 1;
                                w.cur.push(s[*i + 1]);
                                *i += 2;
                            }
                            Some(b'\\') if continuation(&s[*i..]) > 0 => *i += continuation(&s[*i..]),
                            Some(b'`') => return Err(b"command substitution is not supported"),
                            Some(b'$') => {
                                elements += 1;
                                w.empty_at = false;
                                self.dollar(s, i, true, &mut w)?;
                                empty_ats += w.empty_at as usize;
                            }
                            Some(&c) => {
                                elements += 1;
                                w.cur.push(c);
                                *i += 1;
                            }
                        }
                    }
                }
                b'\\' => {
                    // Backslash-newline is a line continuation; otherwise the
                    // next character is taken literally.
                    let Some(&n) = s.get(*i + 1) else { return Err(OPEN_BACKSLASH) };
                    if n == b'\r' && *i + 2 == s.len() {
                        return Err(OPEN_BACKSLASH); // a CRLF line read from stdin
                    }
                    let skip = continuation(&s[*i..]);
                    if skip == 0 {
                        w.cur.push(n);
                        w.has = true;
                    }
                    *i += skip.max(2);
                }
                b'$' => self.dollar(s, i, false, &mut w)?,
                _ => {
                    w.cur.push(c);
                    w.has = true;
                    *i += 1;
                }
            }
        }
        Ok(w.finish())
    }

    /// Value of a parameter, or None if it is unset.
    fn param(&self, name: &[u8], overlay: &[Bytes]) -> Option<Value> {
        let one = |n: u64| {
            let mut tmp = [0u8; 20];
            Some(Value::One(util::fmt_u64(n, &mut tmp).to_vec()))
        };
        match name {
            b"?" => one(self.last as u64),
            b"$" => one(sys::getpid() as u64),
            b"#" => one(self.args.len() as u64 - 1),
            b"@" => Some(Value::Many(self.args[1..].to_vec())),
            b"*" => Some(Value::One(self.args[1..].join(&b' '))),
            b"!" => Some(self.bg).filter(|&pid| pid > 0).and_then(|pid| one(pid as u64)),
            b"-" => {
                let flags = [(self.opt_e, b'e'), (self.opt_x, b'x'), (self.interactive, b'i')];
                Some(Value::One(flags.iter().filter(|f| f.0).map(|f| f.1).collect()))
            }
            b"PPID" => one(sys::getppid() as u64),
            _ => match parse_u64(name) {
                Some(n) => self.args.get(n as usize).map(|v| Value::One(v.clone())),
                None if name.iter().all(u8::is_ascii_digit) => None,
                None => overlay
                    .iter()
                    .rev()
                    .find(|kv| kv.len() > name.len() && kv.starts_with(name) && kv[name.len()] == b'=')
                    .map(|kv| &kv[name.len() + 1..])
                    .or_else(|| getenv(&self.env, name))
                    .map(|v| Value::One(v.to_vec())),
            },
        }
    }

    /// Expand the `$...` at `s[*i]` into `w`.
    fn dollar(&self, s: &[u8], i: &mut usize, quoted: bool, w: &mut Word) -> PResult<()> {
        let mut j = *i + 1;
        while continuation(&s[j..]) > 0 {
            j += continuation(&s[j..]);
        }
        let (value, next) = match s.get(j) {
            Some(b'(') => return Err(b"command substitution is not supported"),
            Some(b'{') => {
                // The matching brace: a default may hold further `${...}`.
                let (mut k, mut depth) = (j + 1, 0);
                let close = loop {
                    match s.get(k) {
                        None => return Err(OPEN_BRACE),
                        Some(b'$') if s.get(k + 1) == Some(&b'{') => {
                            depth += 1;
                            k += 1;
                        }
                        Some(b'}') if depth == 0 => break k,
                        Some(b'}') => depth -= 1,
                        Some(_) => {}
                    }
                    k += 1;
                };
                let inner = &s[j + 1..close];
                // NAME, then nothing or `:-default`. Every other operator
                // (`:?`, `:=`, `#`, `%`, ...) is refused, not read as a name.
                let name_len = match inner.first() {
                    Some(b'?' | b'$' | b'#' | b'@' | b'*' | b'!' | b'-') => 1,
                    Some(c) if c.is_ascii_digit() => inner.iter().take_while(|c| c.is_ascii_digit()).count(),
                    Some(&c) if is_name_start(c) => inner.iter().take_while(|&&c| is_name_char(c)).count(),
                    _ => 0,
                };
                let (name, rest) = inner.split_at(name_len);
                let default = match rest.strip_prefix(b":-").filter(|_| name_len > 0) {
                    Some(d) => Some(self.default_value(d, quoted || w.nosplit, w)?),
                    None if rest.is_empty() && name_len > 0 => None,
                    None => {
                        return Err(b"only ${NAME} and ${NAME:-default} are supported");
                    }
                };
                let is_empty = |v: &Value| match v {
                    Value::One(b) => b.is_empty(),
                    Value::Many(l) => l.is_empty(),
                };
                let value = match (self.param(name, &w.overlay), default) {
                    (Some(v), _) if !is_empty(&v) => v,
                    (_, Some(d)) => Value::One(d),
                    (v, None) => v.unwrap_or(Value::One(Vec::new())),
                };
                (value, close + 1)
            }
            Some(&c) if matches!(c, b'?' | b'$' | b'#' | b'@' | b'*' | b'!' | b'-') || c.is_ascii_digit() => {
                (self.param(&s[j..=j], &w.overlay).unwrap_or(Value::One(Vec::new())), j + 1)
            }
            Some(&c) if is_name_start(c) => {
                let mut k = j;
                while k < s.len() && is_name_char(s[k]) {
                    k += 1;
                }
                (self.param(&s[j..k], &w.overlay).unwrap_or(Value::One(Vec::new())), k)
            }
            Some(b'\'') if !quoted => return Err(b"$'...' quoting is not supported"),
            _ => {
                // A lone `$` is literal.
                w.cur.push(b'$');
                w.has = true;
                *i = j;
                return Ok(());
            }
        };
        *i = next;
        match (value, quoted) {
            (Value::One(v), true) => w.cur.extend_from_slice(&v),
            (Value::One(v), false) if w.nosplit => {
                w.has |= !v.is_empty();
                w.cur.extend_from_slice(&v);
            }
            (Value::One(v), false) => w.split(&v),
            (Value::Many(list), _) if w.nosplit => {
                w.has |= quoted || !list.is_empty();
                w.cur.extend_from_slice(&list.join(&b' '));
            }
            (Value::Many(list), true) => {
                // "$@": one field per positional parameter.
                w.empty_at = list.is_empty();
                for (k, item) in list.iter().enumerate() {
                    if k > 0 {
                        w.fields.push(core::mem::take(&mut w.cur));
                    }
                    w.cur.extend_from_slice(item);
                }
            }
            (Value::Many(list), false) => {
                // Each parameter starts a field of its own; text around the
                // expansion joins the first and the last (`a$@b`).
                for (k, item) in list.iter().enumerate() {
                    if k > 0 {
                        w.end_field();
                    }
                    w.split(item);
                }
            }
        }
        Ok(())
    }

    /// The text after `:-`, with the `$` expansions in it performed. Quoting
    /// inside a default is refused: it would have to change how the result
    /// is split, which this shell does not model.
    fn default_value(&self, d: &[u8], quoted: bool, outer: &Word) -> PResult<Bytes> {
        if outer.depth == 32 {
            return Err(b"${NAME:-default} is nested too deeply");
        }
        let depth = outer.depth + 1;
        let mut out = Word { nosplit: true, overlay: outer.overlay.clone(), depth, ..Word::default() };
        if d.first() == Some(&b'~') {
            return Err(b"`~' expansion is not supported; use $HOME or quote it");
        }
        let mut k = 0;
        while k < d.len() {
            match d[k] {
                b'"' | b'\'' | b'\\' | b'`' => {
                    return Err(b"quotes and backslashes inside ${NAME:-default} are not supported");
                }
                b'*' | b'?' | b'[' if !quoted => {
                    return Err(b"globbing is not supported; quote `*', `?' and `['");
                }
                b'$' if d[k + 1..].starts_with(b"@") || d[k + 1..].starts_with(b"{@") => {
                    return Err(b"$@ inside ${NAME:-default} is not supported");
                }
                b'$' => self.dollar(d, &mut k, true, &mut out)?,
                c => {
                    out.cur.push(c);
                    k += 1;
                }
            }
        }
        Ok(out.cur)
    }
}

/// True if nothing but blanks, newlines, `;` and comments is left.
fn only_blank(mut s: &[u8]) -> bool {
    loop {
        match s.first() {
            None => return true,
            Some(b'#') => s = &s[s.iter().position(|&c| c == b'\n').unwrap_or(s.len())..],
            Some(&c) if is_blank(c) || c == b'\n' || c == b';' => s = &s[1..],
            Some(_) => return false,
        }
    }
}

/// Skip what may stand between `|`, `&&` or `||` and the command that
/// follows: blanks, newlines, line continuations and comments.
fn skip_newlines(s: &[u8], i: &mut usize) {
    loop {
        skip_blanks(s, i);
        match s.get(*i) {
            Some(b'\n') => *i += 1,
            Some(b'#') => *i += s[*i..].iter().position(|&c| c == b'\n').unwrap_or(s.len() - *i),
            _ => return,
        }
    }
}
