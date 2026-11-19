//! A plain, cloneable HTTP response, so prepared segments can be cached and served many times.

use axum::body::Body;
use axum::response::{IntoResponse, Response};
use bytes::Bytes;

#[derive(Clone, Debug)]
pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
}

impl Resp {
    pub fn new(status: u16, body: impl Into<Bytes>) -> Resp {
        Resp { status, headers: Vec::new(), body: body.into() }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Resp {
        self.headers.retain(|(existing, _)| !existing.eq_ignore_ascii_case(name));
        self.headers.push((name.to_string(), value.into()));
        self
    }

    pub fn text(body: impl Into<String>, content_type: &str) -> Resp {
        Resp::new(200, body.into()).header("Content-Type", content_type)
    }

    pub fn json(value: serde_json::Value) -> Resp {
        Resp::json_status(200, value)
    }

    pub fn json_status(status: u16, value: serde_json::Value) -> Resp {
        Resp::new(status, value.to_string()).header("Content-Type", "application/json")
    }

    pub fn error(status: u16, message: impl Into<String>) -> Resp {
        Resp::json_status(status, serde_json::json!({ "ok": false, "error": message.into() }))
    }

    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

impl IntoResponse for Resp {
    fn into_response(self) -> Response {
        let mut builder = Response::builder().status(self.status);
        for (name, value) in &self.headers {
            builder = builder.header(name, value);
        }
        // Everything here is read by the extension, the player page or the TV, from different origins.
        builder = builder
            .header("Access-Control-Allow-Origin", "*")
            .header("Access-Control-Allow-Headers", "Content-Type")
            .header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        builder.body(Body::from(self.body)).unwrap_or_else(|_| Response::new(Body::empty()))
    }
}
