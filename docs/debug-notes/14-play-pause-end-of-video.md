# 14. Video Editor — Play/Pause Bug After End of Video

**Problem:** Playing a recording works the first time, but after the video reaches the end, pressing Space to play again would instantly jump to the last frame instead of restarting playback.

**Root cause:** When AVPlayer reaches the end of the video, its `timeControlStatus` becomes `.paused` internally, but the editor's `isPlaying` state remains `true`. Pressing Space toggles `isPlaying` to `false` (pausing an already-paused player — no-op), then pressing Space again toggles it to `true` and calls `player.play()`. But since the playhead is at the end, `play()` immediately hits end-of-item and the time observer fires with the final timestamp.

**Fix (two parts):**

1. Observe `AVPlayerItem.didPlayToEndTime` notification to reset `isPlaying = false` when the video naturally ends:
```swift
endObserver = NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: newPlayer.currentItem,
    queue: .main
) { _ in
    isPlaying = false
}
```

2. In the `onChange(of: isPlaying)` handler, detect when the player is at the end and seek to the beginning before playing:
```swift
if playing {
    if let item = player?.currentItem {
        let playerTime = player?.currentTime() ?? .zero
        let duration = item.duration
        if duration.isValid, !duration.isIndefinite,
           CMTimeCompare(playerTime, duration) >= 0 {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
    }
    player?.play()
}
```

**Lesson:** AVPlayer doesn't auto-reset to the beginning when playback ends. The app must observe `.AVPlayerItemDidPlayToEndTime` and handle the seek-to-start logic explicitly.
