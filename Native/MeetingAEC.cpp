// Only WebRTC's PCM processing module is used. No audio-device module or HAL writes.
#include "api/audio/audio_processing.h"
#include <new>
struct MeetingAEC {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig format{48000, 1};
};
extern "C" __attribute__((visibility("default"))) void* meeting_aec_create() {
    auto* state = new (std::nothrow) MeetingAEC;
    if (!state) return nullptr;
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false; // AEC3
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.noise_suppression.enabled = false;
    state->apm = webrtc::AudioProcessingBuilder().SetConfig(config).Create();
    if (!state->apm || state->apm->Initialize() != 0) { delete state; return nullptr; }
    return state;
}
extern "C" __attribute__((visibility("default"))) void meeting_aec_destroy(void* value) {
    delete static_cast<MeetingAEC*>(value);
}
extern "C" __attribute__((visibility("default"))) int meeting_aec_reset(void* value) {
    return static_cast<MeetingAEC*>(value)->apm->Initialize();
}
// Exactly 480 mono Float32 samples per input/output. Aligned host-clock frames,
// not callback arrival times; AEC3 estimates the remaining acoustic path delay.
extern "C" __attribute__((visibility("default"))) int meeting_aec_process(
    void* value, const float* render, const float* capture, float* output) {
    auto& s = *static_cast<MeetingAEC*>(value);
    const float* far[] = {render};
    const float* near[] = {capture};
    float* result[] = {output};
    int status = s.apm->AnalyzeReverseStream(far, s.format);
    if (status) return status;
    status = s.apm->set_stream_delay_ms(0);
    if (status) return status;
    return s.apm->ProcessStream(near, s.format, s.format, result);
}
