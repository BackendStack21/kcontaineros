//! A small HTTP server used to demonstrate and test kContainerOS.
//!
//! It answers every request with a fixed body. It deliberately has no signal
//! handling: stopping it cleanly is the job of `/sbin/init`. It is a demo,
//! but it does bound what a client can make it do: connections are capped
//! and a client that sends nothing is dropped after a timeout.

use std::env;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

const BODY: &str = "Hello from kContainerOS\n";
const MAX_CONNECTIONS: usize = 64;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

static ACTIVE: AtomicUsize = AtomicUsize::new(0);

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn handle(mut stream: TcpStream) {
    // A single read is enough here; the request content is ignored.
    let mut buf = [0u8; 4096];
    if matches!(stream.read(&mut buf), Ok(n) if n > 0) {
        respond(&mut stream, "200 OK", BODY);
    }
}

fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let listener = TcpListener::bind(format!("0.0.0.0:{port}")).expect("failed to bind");
    println!("hello-http listening on :{port}");

    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(s) => s,
            Err(_) => {
                // Out of descriptors, most likely: do not spin.
                thread::sleep(Duration::from_millis(50));
                continue;
            }
        };
        let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
        let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
        if ACTIVE.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            ACTIVE.fetch_sub(1, Ordering::SeqCst);
            respond(&mut stream, "503 Service Unavailable", "busy\n");
            continue;
        }
        thread::spawn(move || {
            handle(stream);
            ACTIVE.fetch_sub(1, Ordering::SeqCst);
        });
    }
}
