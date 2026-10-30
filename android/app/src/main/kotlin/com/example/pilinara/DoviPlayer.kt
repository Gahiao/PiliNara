package com.example.pilinara

import android.app.Activity
import android.net.Uri
import android.util.Log
import android.view.SurfaceView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource

/**
 * 杜比视界 profile 5 的 Media3 视频解码器（实验）。
 *
 * 视频由 ExoPlayer/MediaCodec 按 DoVi 流解码到应用的原生 SurfaceView，
 * 音频仍由 mpv 播放；控制器负责把视频位置同步到 mpv，避免音画不同步。
 */
class DoviPlayer(
    private val activity: Activity,
    private val surfaceProvider: () -> SurfaceView?,
) {
    companion object {
        private const val TAG = "DoviPlayer"
    }

    private var player: ExoPlayer? = null

    fun prepare(
        url: String,
        audioUrl: String?,
        referer: String,
        userAgent: String,
    ): Boolean {
        release()
        val surfaceView = surfaceProvider()
        if (surfaceView == null) {
            Log.w(TAG, "prepare: native SurfaceView not ready")
            return false
        }
        return runCatching {
            fun source(u: String): ProgressiveMediaSource {
                val dataSourceFactory = DefaultHttpDataSource.Factory()
                    .setUserAgent(userAgent)
                    .setDefaultRequestProperties(
                        mapOf(
                            "Referer" to referer,
                            "User-Agent" to userAgent,
                        ),
                    )
                    .setAllowCrossProtocolRedirects(true)
                return ProgressiveMediaSource.Factory(dataSourceFactory)
                    .createMediaSource(MediaItem.fromUri(Uri.parse(u)))
            }

            // B 站 DASH 的音视频是分开的，videoSource 本身没有音轨；
            // 有 audioSource 时用 MergingMediaSource 合并，否则 ExoPlayer
            // 只有视频，音轨会完全缺失。
            val videoSource = source(url)
            val mediaSource = if (audioUrl.isNullOrEmpty()) {
                videoSource
            } else {
                MergingMediaSource(videoSource, source(audioUrl))
            }
            val renderers = DefaultRenderersFactory(activity)
                .setEnableDecoderFallback(true)
            val exo = ExoPlayer.Builder(activity, renderers).build()
            exo.setVideoSurfaceView(surfaceView)
            exo.volume = 1f
            exo.playWhenReady = true
            exo.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    Log.w(TAG, "playback error: ${error.errorCodeName}", error)
                    // 音频轨合并失败（例如 Dolby/EC3 音轨）时回退到纯视频，
                    // 避免整个杜比视频黑屏。
                    if (!audioUrl.isNullOrEmpty()) {
                        prepare(url, null, referer, userAgent)
                    }
                }
            })
            exo.setMediaSource(mediaSource)
            exo.prepare()
            player = exo
            true
        }.onFailure {
            Log.w(TAG, "prepare failed", it)
        }.getOrDefault(false)
    }

    fun play() {
        player?.play()
    }

    fun pause() {
        player?.pause()
    }

    fun seekTo(positionMs: Long) {
        player?.seekTo(positionMs.coerceAtLeast(0L))
    }

    fun setRate(rate: Float) {
        player?.setPlaybackSpeed(rate.coerceAtLeast(0.1f))
    }

    fun setVolume(volume: Float) {
        player?.volume = volume.coerceIn(0f, 1f)
    }

    fun position(): Long = player?.currentPosition ?: 0L

    fun release() {
        runCatching { player?.release() }
        player = null
    }
}
