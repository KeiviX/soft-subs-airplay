//! Some sites disguise HLS segments as images: `.jpg` names, an `image/png` type, sometimes fake PNG/JPEG
//! bytes in front of the real MPEG-TS data. hls.js tolerates that; TVs don't, so find the TS data.

/// Where the MPEG-TS data starts, or None for anything that isn't MPEG-TS.
pub fn ts_offset(data: &[u8]) -> Option<usize> {
    let bytes = &data[..data.len().min(64 * 1024)];
    if bytes.len() <= 188 * 3 {
        return None;
    }
    if is_ts(bytes, 0) {
        return Some(0);
    }
    // Fragmented MP4 is never wrapped this way; don't mistake its payload for TS sync bytes.
    if matches!(&bytes[4..8], b"ftyp" | b"styp" | b"moof" | b"sidx") {
        return None;
    }
    (1..bytes.len() - 188 * 2).find(|&offset| is_ts(bytes, offset))
}

fn is_ts(bytes: &[u8], offset: usize) -> bool {
    offset + 376 < bytes.len() && bytes[offset] == 0x47 && bytes[offset + 188] == 0x47 && bytes[offset + 376] == 0x47
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(packets: usize) -> Vec<u8> {
        let mut data = vec![0u8; packets * 188];
        for packet in 0..packets {
            data[packet * 188] = 0x47;
        }
        data
    }

    #[test]
    fn plain_ts() {
        assert_eq!(ts_offset(&ts(10)), Some(0));
    }

    #[test]
    fn png_prefix() {
        let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
        data.resize(252, 0);
        data.extend(ts(10));
        assert_eq!(ts_offset(&data), Some(252));
    }

    #[test]
    fn mp4_is_left_alone() {
        let mut data = vec![0, 0, 0, 24];
        data.extend(b"ftyp");
        data.extend(ts(10));
        assert_eq!(ts_offset(&data), None);
    }
}
