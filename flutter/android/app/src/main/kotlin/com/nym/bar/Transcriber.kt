package com.nym.bar

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

object Transcriber {
    const val CHANNEL = "app.nymchat/transcribe"
    private const val TIMEOUT_EXTRA_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var active: SpeechRecognizer? = null

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val lang = call.argument<String>("lang") ?: java.util.Locale.getDefault().toLanguageTag()
        when (call.method) {
            "availability" -> availability(context, lang, result)
            "install" -> install(context, lang, result)
            "transcribe" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "path missing", null)
                } else {
                    transcribe(context, path, lang, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun unavailable(reason: String) = mapOf("status" to "unavailable", "reason" to reason)

    private fun availability(context: Context, lang: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success(unavailable("os_too_old"))
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.success(unavailable("no_engine"))
            return
        }
        checkSupport(context, lang, result)
    }

    @RequiresApi(33)
    private fun checkSupport(context: Context, lang: String, result: MethodChannel.Result) {
        main.post {
            val recognizer = try {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } catch (e: Throwable) {
                result.success(unavailable("no_engine"))
                return@post
            }
            var answered = false
            fun answer(value: Map<String, String>) {
                if (answered) return
                answered = true
                main.post { recognizer.destroy() }
                result.success(value)
            }
            try {
                recognizer.checkRecognitionSupport(
                    baseIntent(lang),
                    worker,
                    object : RecognitionSupportCallback {
                        override fun onSupportResult(support: RecognitionSupport) {
                            val wanted = lang.lowercase()
                            val base = wanted.substringBefore('-')
                            fun has(list: List<String>) = list.any {
                                val l = it.lowercase()
                                l == wanted || l.substringBefore('-') == base
                            }
                            when {
                                has(support.installedOnDeviceLanguages) -> answer(mapOf("status" to "available"))
                                has(support.pendingOnDeviceLanguages) -> answer(mapOf("status" to "downloading"))
                                has(support.supportedOnDeviceLanguages) -> answer(mapOf("status" to "downloadable"))
                                else -> answer(unavailable("no_model"))
                            }
                        }

                        override fun onError(error: Int) {
                            answer(mapOf("status" to "available"))
                        }
                    },
                )
            } catch (e: Throwable) {
                answer(mapOf("status" to "available"))
            }
        }
    }

    private fun install(context: Context, lang: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success(false)
            return
        }
        main.post { download(context, lang, result) }
    }

    @RequiresApi(33)
    private fun download(context: Context, lang: String, result: MethodChannel.Result) {
        try {
            val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            recognizer.triggerModelDownload(baseIntent(lang))
            main.postDelayed({ recognizer.destroy() }, 1000)
            result.success(true)
        } catch (e: Throwable) {
            result.success(false)
        }
    }

    private fun baseIntent(lang: String): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }

    private class Source(val sampleRate: Int, val channels: Int, val durationUs: Long)

    private fun probe(path: String): Pair<MediaExtractor, Source> {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (!mime.startsWith("audio/")) continue
            extractor.selectTrack(i)
            val rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val duration = if (f.containsKey(MediaFormat.KEY_DURATION)) f.getLong(MediaFormat.KEY_DURATION) else 0L
            return extractor to Source(rate, channels, duration)
        }
        extractor.release()
        throw IllegalStateException("no audio track")
    }

    private fun decodeTo(extractor: MediaExtractor, out: OutputStream) {
        val index = extractor.sampleTrackIndex.coerceAtLeast(0)
        val format = extractor.getTrackFormat(index)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (outIndex >= 0) {
                    val buf = codec.getOutputBuffer(outIndex)!!
                    val chunk = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.get(chunk, 0, info.size)
                    codec.releaseOutputBuffer(outIndex, false)
                    out.write(if (channels > 1) downmix(chunk, channels) else chunk)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
        } finally {
            codec.stop()
            codec.release()
        }
    }

    private fun downmix(pcm: ByteArray, channels: Int): ByteArray {
        val frames = pcm.size / (2 * channels)
        val out = ByteArray(frames * 2)
        for (f in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) {
                val i = (f * channels + c) * 2
                sum += (pcm[i].toInt() and 0xFF) or (pcm[i + 1].toInt() shl 8)
            }
            val v = (sum / channels).coerceIn(-32768, 32767)
            out[f * 2] = (v and 0xFF).toByte()
            out[f * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }

    private fun transcribe(context: Context, path: String, lang: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.error("os_too_old", "needs Android 13", null)
            return
        }
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.error("no_engine", "no on-device recognizer", null)
            return
        }
        val probed = try {
            probe(path)
        } catch (e: Throwable) {
            result.error("failed", e.message, null)
            return
        }
        start(context, lang, probed.first, probed.second, result)
    }

    @RequiresApi(33)
    private fun start(context: Context, lang: String, extractor: MediaExtractor, source: Source, result: MethodChannel.Result) {
        val pipe = ParcelFileDescriptor.createPipe()
        val read = pipe[0]
        val write = pipe[1]
        main.post {
            active?.destroy()
            val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            active = recognizer
            val parts = StringBuilder()
            var finished = false
            fun finish(text: String?, code: String?) {
                if (finished) return
                finished = true
                main.post {
                    recognizer.destroy()
                    if (active === recognizer) active = null
                }
                try { read.close() } catch (_: Throwable) { }
                if (code == null) result.success(text ?: "") else result.error(code, code, null)
            }
            fun collect(bundle: Bundle?) {
                val list = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val best = list?.firstOrNull()?.trim()
                if (!best.isNullOrEmpty()) {
                    if (parts.isNotEmpty()) parts.append(' ')
                    parts.append(best)
                }
            }
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onSegmentResults(segmentResults: Bundle) = collect(segmentResults)
                override fun onEndOfSegmentedSession() = finish(parts.toString(), null)
                override fun onResults(results: Bundle?) {
                    collect(results)
                    finish(parts.toString(), null)
                }
                override fun onError(error: Int) {
                    when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> finish(parts.toString(), null)
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> finish(null, "no_model")
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> finish(null, "denied")
                        else -> finish(null, "failed")
                    }
                }
            })
            val intent = baseIntent(lang).apply {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, source.sampleRate)
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            }
            recognizer.startListening(intent)
            worker.execute {
                try {
                    ParcelFileDescriptor.AutoCloseOutputStream(write).use { out -> decodeTo(extractor, out) }
                } catch (_: Throwable) {
                } finally {
                    extractor.release()
                }
            }
            val limit = source.durationUs / 1000 + TIMEOUT_EXTRA_MS
            main.postDelayed({ if (!finished) finish(parts.toString().ifEmpty { null }, if (parts.isEmpty()) "failed" else null) }, limit)
        }
    }
}
