#ifndef AUDIOLINK_REALTIME_SUPPORT_H
#define AUDIOLINK_REALTIME_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

typedef struct ALRecordingAccumulator ALRecordingAccumulator;

/*
 * A bounded single-producer capture buffer. Creation and destruction happen
 * off the audio callback. append() performs no allocation, locking, logging,
 * actor hop, or I/O. The consumer must call stop() before taking a snapshot.
 */
ALRecordingAccumulator *al_recording_accumulator_create(size_t capacity);
void al_recording_accumulator_stop(ALRecordingAccumulator *accumulator);
void al_recording_accumulator_destroy(ALRecordingAccumulator *accumulator);
void al_recording_accumulator_append(ALRecordingAccumulator *accumulator,
                                     const float *samples,
                                     size_t count,
                                     int sample_time_valid,
                                     double sample_time);
size_t al_recording_accumulator_count(const ALRecordingAccumulator *accumulator);
void al_recording_accumulator_copy(const ALRecordingAccumulator *accumulator,
                                   float *destination,
                                   size_t count);
uint64_t al_recording_accumulator_buffer_count(const ALRecordingAccumulator *accumulator);
uint64_t al_recording_accumulator_dropped_count(const ALRecordingAccumulator *accumulator);
uint64_t al_recording_accumulator_overflow_count(const ALRecordingAccumulator *accumulator);
int al_recording_accumulator_has_first_sample_time(const ALRecordingAccumulator *accumulator);
double al_recording_accumulator_first_sample_time(const ALRecordingAccumulator *accumulator);
double al_recording_accumulator_last_sample_time(const ALRecordingAccumulator *accumulator);

#endif
