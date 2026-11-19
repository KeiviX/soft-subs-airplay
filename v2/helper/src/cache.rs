//! Downloads segments ahead of the player and keeps them in memory.
//!
//! An AirPlay TV keeps only a few seconds buffered, fetches each segment just before it needs it, and gives up
//! on a request after about 5 seconds. Fetching from the video host only when the TV asks put every CDN hiccup
//! straight into playback. With the next minute or so already on this computer, the TV's requests are answered
//! at LAN speed, and a slow or stuck download is retried before the TV notices.

use futures::future::{BoxFuture, FutureExt, Shared};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use url::Url;

use crate::log;
use crate::resp::Resp;

pub type Fetch = Arc<dyn Fn(Url) -> BoxFuture<'static, Resp> + Send + Sync>;
type Pending = Shared<BoxFuture<'static, Resp>>;

/// How far ahead of the newest request to keep segments ready.
const LOOKAHEAD_SECONDS: f64 = 90.0;
const MAX_LOOKAHEAD_SEGMENTS: usize = 24;
const WORKERS: usize = 2;
const BYTE_LIMIT: usize = 400 << 20;

pub struct SegmentCache {
    fetch: Fetch,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    ready: HashMap<Url, Resp>,
    /// Least recently used first.
    usage: VecDeque<Url>,
    bytes: usize,
    in_flight: HashMap<Url, Pending>,
    lists: Vec<Vec<(Url, f64)>>,
    position: HashMap<Url, (usize, usize)>,
    /// Segments the workers should fetch next, in order.
    wanted: Vec<Url>,
    active_workers: usize,
}

impl State {
    fn needs_download(&self, url: &Url) -> bool {
        !self.ready.contains_key(url) && !self.in_flight.contains_key(url)
    }

    fn touch(&mut self, url: &Url) {
        if let Some(index) = self.usage.iter().position(|existing| existing == url) {
            self.usage.remove(index);
        }
        self.usage.push_back(url.clone());
    }

    fn evict(&mut self) {
        while self.bytes > BYTE_LIMIT {
            let Some(oldest) = self.usage.pop_front() else { break };
            if let Some(response) = self.ready.remove(&oldest) {
                self.bytes -= response.body.len();
            }
        }
    }
}

impl SegmentCache {
    pub fn new(fetch: Fetch) -> Arc<SegmentCache> {
        Arc::new(SegmentCache { fetch, state: Mutex::new(State::default()) })
    }

    /// Records a media playlist's segments so requests for them can be prefetched and served from memory.
    pub fn register(&self, segments: Vec<(Url, f64)>) {
        let mut state = self.state.lock().unwrap();
        let Some(first) = segments.first() else { return };
        if state.position.contains_key(&first.0) {
            return;
        }
        let list = state.lists.len();
        for (index, (url, _)) in segments.iter().enumerate() {
            state.position.entry(url.clone()).or_insert((list, index));
        }
        state.lists.push(segments);
    }

    pub fn is_segment(&self, url: &Url) -> bool {
        self.state.lock().unwrap().position.contains_key(url)
    }

    /// The segment's response, from memory if it's ready, otherwise as soon as its download finishes.
    pub async fn response(self: &Arc<Self>, url: Url) -> Resp {
        self.plan_ahead(&url);
        let cached = {
            let mut state = self.state.lock().unwrap();
            let cached = state.ready.get(&url).cloned();
            if cached.is_some() {
                state.touch(&url);
            }
            cached
        };
        if let Some(response) = cached {
            log::log(format!("served from cache {}", short_name(&url)));
            return response;
        }
        self.download(url).await
    }

    fn download(self: &Arc<Self>, url: Url) -> Pending {
        let mut state = self.state.lock().unwrap();
        if let Some(pending) = state.in_flight.get(&url) {
            return pending.clone();
        }
        let cache = Arc::clone(self);
        let fetch = Arc::clone(&self.fetch);
        let key = url.clone();
        let pending = async move {
            let response = fetch(key.clone()).await;
            cache.finished(&key, &response);
            response
        }
        .boxed()
        .shared();
        state.in_flight.insert(url, pending.clone());
        drop(state);
        // Keep the download going even if whoever asked for it (the TV, say) gives up and disconnects.
        tokio::spawn(pending.clone());
        pending
    }

    fn finished(&self, url: &Url, response: &Resp) {
        let mut state = self.state.lock().unwrap();
        state.in_flight.remove(url);
        if !response.ok() || state.ready.contains_key(url) {
            return;
        }
        state.ready.insert(url.clone(), response.clone());
        state.usage.push_back(url.clone());
        state.bytes += response.body.len();
        state.evict();
    }

    /// Queues the segments after `url` (up to the lookahead) and starts workers to fetch them.
    fn plan_ahead(self: &Arc<Self>, url: &Url) {
        let mut state = self.state.lock().unwrap();
        let Some(&(list, index)) = state.position.get(url) else { return };
        let mut upcoming = Vec::new();
        let mut seconds = 0.0;
        for (next, duration) in state.lists[list].iter().skip(index + 1) {
            if seconds >= LOOKAHEAD_SECONDS || upcoming.len() >= MAX_LOOKAHEAD_SEGMENTS {
                break;
            }
            upcoming.push(next.clone());
            seconds += duration;
        }
        // Keep what's around the playhead; anything else can go first when memory runs short.
        for next in upcoming.iter().rev() {
            if state.ready.contains_key(next) {
                state.touch(next);
            }
        }
        state.wanted = upcoming;
        let pending = state.wanted.iter().filter(|next| state.needs_download(next)).count();
        let mut to_start = WORKERS.saturating_sub(state.active_workers).min(pending);
        while to_start > 0 {
            state.active_workers += 1;
            to_start -= 1;
            let cache = Arc::clone(self);
            tokio::spawn(async move { cache.work().await });
        }
    }

    async fn work(self: Arc<Self>) {
        loop {
            let next = {
                let state = self.state.lock().unwrap();
                state.wanted.iter().find(|url| state.needs_download(url)).cloned()
            };
            let Some(url) = next else { break };
            let response = self.download(url.clone()).await;
            if !response.ok() {
                // The host is refusing or failing; don't hammer it. The player's own request will try again.
                self.state.lock().unwrap().wanted.retain(|wanted| wanted != &url);
            }
        }
        self.state.lock().unwrap().active_workers -= 1;
    }
}

fn short_name(url: &Url) -> String {
    url.path_segments().and_then(|mut parts| parts.next_back()).unwrap_or("").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn urls(count: usize) -> Vec<(Url, f64)> {
        (0..count).map(|i| (Url::parse(&format!("https://cdn.example/seg{i}.ts")).unwrap(), 4.0)).collect()
    }

    #[tokio::test]
    async fn prefetches_and_serves_from_memory() {
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&calls);
        let cache = SegmentCache::new(Arc::new(move |url: Url| {
            counter.fetch_add(1, Ordering::SeqCst);
            async move { Resp::new(200, url.to_string()) }.boxed()
        }));
        let segments = urls(40);
        cache.register(segments.clone());

        let first = cache.response(segments[0].0.clone()).await;
        assert_eq!(first.body, segments[0].0.to_string());
        // Give the workers a moment to fetch the lookahead (90 s of 4 s segments, capped at 24).
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert_eq!(calls.load(Ordering::SeqCst), 1 + 23);

        let before = calls.load(Ordering::SeqCst);
        let fifth = cache.response(segments[5].0.clone()).await;
        assert_eq!(fifth.body, segments[5].0.to_string());
        assert_eq!(calls.load(Ordering::SeqCst), before, "segment 5 should come from memory");
    }

    #[tokio::test]
    async fn concurrent_requests_share_one_download() {
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&calls);
        let cache = SegmentCache::new(Arc::new(move |url: Url| {
            counter.fetch_add(1, Ordering::SeqCst);
            async move {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                Resp::new(200, url.to_string())
            }
            .boxed()
        }));
        let url = Url::parse("https://cdn.example/only.ts").unwrap();
        cache.register(vec![(url.clone(), 4.0)]);
        let (a, b) = tokio::join!(cache.response(url.clone()), cache.response(url.clone()));
        assert_eq!(a.body, b.body);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
}
