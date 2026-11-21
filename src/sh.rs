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
        if self.has && !(self.empty_at && self.cur.is_empty() && self.fields.is_empty()) {
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
    };

    let mut i = 1;
    let mut command: Option<&Bytes> = None;
    while i < args.len() {
        let a = &args[i][..];
        if a == b"-c" {
            if i + 1 >= args.len() {
                eprint(&[b"sh: -c requires an argument\n"]);
                return 2;
            }
            command = Some(&args[i + 1]);
            i += 2;
            break;
        } else if a == b"--" {
            i += 1;
            break;
        } else if a.len() > 1 && a[0] == b'-' {
            if !sh.set_flags(a) {
                return 2;
            }
            i += 1;
        } else {
            break;
        }
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
        while sh.unfinished(&input) {
            if sh.interactive {
                eprint(&[b"> "]);
            }
            let Some(more) = read_line() else { break };
            input.push(b'\n');
            input.extend_from_slice(&more);
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

fn reap_background() {
    let mut st = 0;
    while sys::wait4(-1, &mut st, sys::WNOHANG) > 0 {}
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

fn skip_blanks(s: &[u8], i: &mut usize) {
    while *i < s.len() {
        if is_blank(s[*i]) {
            *i += 1;
        } else if s[*i] == b'\\' && s.get(*i + 1) == Some(&b'\n') {
            *i += 2;
        } else {
            break;
        }
    }
}

fn is_builtin(name: &[u8]) -> bool {
    matches!(
        name,
        b":" | b"cd" | b"exit" | b"export" | b"unset" | b"exec" | b"set" | b"shift" | b"wait"
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
        let on = a[0] == b'-';
        for &f in &a[1..] {
            match f {
                b'e' => self.opt_e = on,
                b'x' => self.opt_x = on,
                _ => {
                    eprint(&[b"sh: unsupported option: ", a, b" (only -e and -x)\n"]);
                    return false;
                }
            }
        }
        true
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
        loop {
            reap_background();
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
            go = match sep {
                Sep::End => return self.last,
                Sep::And => self.last == 0,
                Sep::Or => self.last != 0,
                _ => true,
            };
        }
    }

    /// Parse the whole of `src` without running anything.
    fn check(&self, src: &[u8]) -> PResult<()> {
        let mut i = 0;
        while self.parse_pipeline(src, &mut i)?.1 != Sep::End {}
        Ok(())
    }

    /// True if `src` stops in the middle of a quote, `${`, a pipeline or an
    /// and-or list, or right after a backslash.
    fn unfinished(&self, src: &[u8]) -> bool {
        matches!(self.check(src), Err(e) if UNFINISHED.contains(&e))
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
                for a in &c.assigns {
                    self.setenv(a);
                }
                return self.builtin_redirected(c);
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
                }
                if !last {
                    sys::close(pfd[0]);
                    sys::dup3(pfd[1], 1);
                    sys::close(pfd[1]);
                }
                if self.interactive {
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
        let e = util::exec(argv, &self.env);
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
        eprint(&[b"sh: ", &argv[0], b": ", errstr(e), b"\n"]);
        sys::exit(if e == sys::ENOENT { 127 } else { 126 })
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
        if status == 0 {
            status = if apply_redirs(&c.redirs) { self.builtin(c, false) } else { 1 };
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
                let dir: &[u8] = match a.get(1) {
                    Some(d) => d,
                    None => getenv(&self.env, b"HOME").unwrap_or(b"/"),
                };
                let e = sys::chdir(cz(dir).as_ptr());
                if e < 0 {
                    eprint(&[b"sh: cd: ", dir, b": ", errstr(e), b"\n"]);
                    return 1;
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
                for kv in &a[1..] {
                    if kv.contains(&b'=') {
                        self.setenv(kv);
                    }
                }
                0
            }
            b"unset" => {
                for k in &a[1..] {
                    self.env.retain(|e| !(e.starts_with(k) && e.get(k.len()) == Some(&b'=')));
                }
                0
            }
            b"exec" => {
                if !in_child && !apply_redirs(&c.redirs) {
                    sys::exit(1);
                }
                if a.len() == 1 {
                    return 0;
                }
                self.exec_or_die(&a[1..])
            }
            b"set" => {
                for arg in &a[1..] {
                    let is_flag = arg.len() > 1 && (arg[0] == b'-' || arg[0] == b'+');
                    if !is_flag {
                        eprint(&[b"sh: set: only -e and -x are supported\n"]);
                        return 2;
                    }
                    if !self.set_flags(arg) {
                        return 2;
                    }
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
                    _ => {
                        eprint(&[b"sh: shift: cannot shift that many\n"]);
                        1
                    }
                }
            }
            b"wait" => {
                let mut st = 0;
                while sys::wait4(-1, &mut st, 0) > 0 {}
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
            let empty = c.argv.is_empty() && c.assigns.is_empty() && c.redirs.is_empty();
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
                skip_newlines(s, i);
                if only_blank(&s[*i..]) {
                    return Err(OPEN_LIST);
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
                let words = self.parse_word(s, i)?;
                if *i == start {
                    return Err(b"missing redirection target");
                }
                // What it expands to is only known when the command runs.
                let target = if words.is_empty() { None } else { Some(words.join(&b' ')) };
                cmd.redirs.push(Redir { fd, kind, target });
                continue;
            }

            // `NAME=value` before the command name.
            if cmd.argv.is_empty() && is_name_start(c) {
                let mut k = *i;
                while k < s.len() && is_name_char(s[k]) {
                    k += 1;
                }
                if s.get(k) == Some(&b'=') {
                    let mut kv = s[*i..=k].to_vec();
                    *i = k + 1;
                    kv.extend_from_slice(&self.parse_word(s, i)?.join(&b' '));
                    cmd.assigns.push(kv);
                    continue;
                }
            }

            let start = *i;
            let words = self.parse_word(s, i)?;
            if cmd.argv.is_empty() && RESERVED.contains(&&s[start..*i]) {
                return Err(b"if, for, while, case, { } and ! are not supported");
            }
            cmd.argv.extend(words);
        }
        Ok(cmd)
    }

    /// Parse and expand one word into zero or more fields.
    fn parse_word(&self, s: &[u8], i: &mut usize) -> PResult<Vec<Bytes>> {
        let mut w = Word::default();
        while *i < s.len() {
            let c = s[*i];
            match c {
                b' ' | b'\t' | b'\r' | b'\n' | b';' | b'|' | b'&' | b'<' | b'>' => break,
                b'(' | b')' => return Err(b"subshells and functions are not supported"),
                b'*' | b'?' | b'[' => {
                    return Err(b"globbing is not supported; quote `*', `?' and `['")
                }
                b'~' if w.cur.is_empty() && !w.has => {
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
                    w.has = true;
                    *i += 1;
                    loop {
                        match s.get(*i) {
                            None => return Err(OPEN_DOUBLE),
                            Some(b'"') => {
                                *i += 1;
                                break;
                            }
                            Some(b'\\') if matches!(s.get(*i + 1), Some(b'"' | b'$' | b'\\' | b'`')) => {
                                w.cur.push(s[*i + 1]);
                                *i += 2;
                            }
                            Some(b'\\') if s.get(*i + 1) == Some(&b'\n') => *i += 2,
                            Some(b'$') => self.dollar(s, i, true, &mut w)?,
                            Some(&c) => {
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
                    if n != b'\n' {
                        w.cur.push(n);
                        w.has = true;
                    }
                    *i += 2;
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
    fn param(&self, name: &[u8]) -> Option<Value> {
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
            _ => match parse_u64(name) {
                Some(n) => self.args.get(n as usize).map(|v| Value::One(v.clone())),
                None => getenv(&self.env, name).map(|v| Value::One(v.to_vec())),
            },
        }
    }

    /// Expand the `$...` at `s[*i]` into `w`.
    fn dollar(&self, s: &[u8], i: &mut usize, quoted: bool, w: &mut Word) -> PResult<()> {
        let j = *i + 1;
        let (value, next) = match s.get(j) {
            Some(b'(') => return Err(b"command substitution is not supported"),
            Some(b'{') => {
                let len = s[j + 1..]
                    .iter()
                    .position(|&c| c == b'}')
                    .ok_or(OPEN_BRACE)?;
                let inner = &s[j + 1..j + 1 + len];
                let (name, default) = match inner.windows(2).position(|p| p == b":-") {
                    Some(p) => (&inner[..p], Some(&inner[p + 2..])),
                    None => (inner, None),
                };
                let is_empty = |v: &Value| match v {
                    Value::One(b) => b.is_empty(),
                    Value::Many(l) => l.is_empty(),
                };
                let value = match (self.param(name), default) {
                    (Some(v), _) if !is_empty(&v) => v,
                    (_, Some(d)) => Value::One(d.to_vec()),
                    (v, None) => v.unwrap_or(Value::One(Vec::new())),
                };
                (value, j + len + 2)
            }
            Some(&c) if matches!(c, b'?' | b'$' | b'#' | b'@' | b'*') || c.is_ascii_digit() => {
                (self.param(&s[j..=j]).unwrap_or(Value::One(Vec::new())), j + 1)
            }
            Some(&c) if is_name_start(c) => {
                let mut k = j;
                while k < s.len() && is_name_char(s[k]) {
                    k += 1;
                }
                (self.param(&s[j..k]).unwrap_or(Value::One(Vec::new())), k)
            }
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
            (Value::One(v), false) => w.split(&v),
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
                for item in &list {
                    w.split(item);
                    w.end_field();
                }
            }
        }
        Ok(())
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

fn skip_newlines(s: &[u8], i: &mut usize) {
    while *i < s.len() && (is_blank(s[*i]) || s[*i] == b'\n') {
        *i += 1;
    }
}
