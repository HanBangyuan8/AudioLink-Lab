#include "AudioLinkRealtimeSupport.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct ALRecordingAccumulator {
    size_t capacity;
    float *samples;
    _Atomic size_t written_count;
    _Atomic uint64_t buffer_count;
    _Atomic uint64_t dropped_count;
    _Atomic uint64_t overflow_count;
    _Atomic int active;
    double first_sample_time;
    double last_sample_time;
    double previous_end_sample_time;
    int has_first_sample_time;
    int has_previous_end_sample_time;
};

ALRecordingAccumulator *al_recording_accumulator_create(size_t capacity) {
    if (capacity == 0) return NULL;
    ALRecordingAccumulator *accumulator = (ALRecordingAccumulator *)calloc(1, sizeof(*accumulator));
    if (accumulator == NULL) return NULL;
    accumulator->samples = (float *)calloc(capacity, sizeof(float));
    if (accumulator->samples == NULL) {
        free(accumulator);
        return NULL;
    }
    accumulator->capacity = capacity;
    atomic_init(&accumulator->written_count, 0);
    atomic_init(&accumulator->buffer_count, 0);
    atomic_init(&accumulator->dropped_count, 0);
    atomic_init(&accumulator->overflow_count, 0);
    atomic_init(&accumulator->active, 1);
    return accumulator;
}

void al_recording_accumulator_stop(ALRecordingAccumulator *accumulator) {
    if (accumulator == NULL) return;
    atomic_store_explicit(&accumulator->active, 0, memory_order_release);
}

void al_recording_accumulator_destroy(ALRecordingAccumulator *accumulator) {
    if (accumulator == NULL) return;
    free(accumulator->samples);
    free(accumulator);
}

void al_recording_accumulator_append(ALRecordingAccumulator *accumulator,
                                     const float *samples,
                                     size_t count,
                                     int sample_time_valid,
                                     double sample_time) {
    if (accumulator == NULL || samples == NULL || count == 0) return;
    if (atomic_load_explicit(&accumulator->active, memory_order_acquire) == 0) {
        atomic_fetch_add_explicit(&accumulator->dropped_count, 1, memory_order_relaxed);
        return;
    }

    atomic_fetch_add_explicit(&accumulator->buffer_count, 1, memory_order_relaxed);
    if (sample_time_valid) {
        if (!accumulator->has_first_sample_time) {
            accumulator->first_sample_time = sample_time;
            accumulator->has_first_sample_time = 1;
        }
        if (accumulator->has_previous_end_sample_time &&
            (sample_time - accumulator->previous_end_sample_time > 1.0 ||
             accumulator->previous_end_sample_time - sample_time > 1.0)) {
            atomic_fetch_add_explicit(&accumulator->dropped_count, 1, memory_order_relaxed);
        }
        accumulator->last_sample_time = sample_time + (double)(count - 1);
        accumulator->previous_end_sample_time = sample_time + (double)count;
        accumulator->has_previous_end_sample_time = 1;
    }

    // This is intentionally single-producer. A bounded load/store avoids the
    // size_t wraparound that an unchecked fetch_add would permit after an
    // extremely long capture window.
    size_t start = atomic_load_explicit(&accumulator->written_count, memory_order_relaxed);
    size_t writable = 0;
    if (start < accumulator->capacity) {
        writable = accumulator->capacity - start;
        if (writable > count) writable = count;
        memcpy(accumulator->samples + start, samples, writable * sizeof(float));
        atomic_store_explicit(&accumulator->written_count, start + writable, memory_order_release);
    }
    if (writable < count) {
        atomic_fetch_add_explicit(&accumulator->overflow_count, 1, memory_order_relaxed);
    }
}

size_t al_recording_accumulator_count(const ALRecordingAccumulator *accumulator) {
    if (accumulator == NULL) return 0;
    size_t count = atomic_load_explicit(&accumulator->written_count, memory_order_acquire);
    return count < accumulator->capacity ? count : accumulator->capacity;
}

void al_recording_accumulator_copy(const ALRecordingAccumulator *accumulator,
                                   float *destination,
                                   size_t count) {
    if (accumulator == NULL || destination == NULL) return;
    size_t available = al_recording_accumulator_count(accumulator);
    if (count > available) count = available;
    memcpy(destination, accumulator->samples, count * sizeof(float));
}

uint64_t al_recording_accumulator_buffer_count(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0 : atomic_load_explicit(&accumulator->buffer_count, memory_order_acquire);
}

uint64_t al_recording_accumulator_dropped_count(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0 : atomic_load_explicit(&accumulator->dropped_count, memory_order_acquire);
}

uint64_t al_recording_accumulator_overflow_count(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0 : atomic_load_explicit(&accumulator->overflow_count, memory_order_acquire);
}

int al_recording_accumulator_has_first_sample_time(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0 : accumulator->has_first_sample_time;
}

double al_recording_accumulator_first_sample_time(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0.0 : accumulator->first_sample_time;
}

double al_recording_accumulator_last_sample_time(const ALRecordingAccumulator *accumulator) {
    return accumulator == NULL ? 0.0 : accumulator->last_sample_time;
}
