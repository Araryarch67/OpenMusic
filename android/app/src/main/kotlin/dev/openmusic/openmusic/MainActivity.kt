package dev.openmusic.openmusic

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service's activity shares its Flutter engine with the playback service,
// so music keeps playing (with its notification) after the app is closed.
class MainActivity : AudioServiceActivity()
