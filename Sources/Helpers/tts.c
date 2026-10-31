// lingveil-tts: speaks with an open-source narration model through sherpa-onnx.
//
// Started by Lingveil on demand and kept running while it is being used, so the model is
// loaded once; it exits after two idle minutes (or when Lingveil closes its stdin), which
// gives the memory back. The sherpa-onnx runtime is downloaded by Lingveil and loaded here
// with dlopen, so nothing of it ships with the app.
//
// usage: lingveil-tts <runtime dir> <kind: vits|kokoro|kitten|supertonic> <model dir> <threads>
// stdin, one request per line:   <speaker id>\t<speed>\t<language>\t<text>\n
// stdout per request:            int32 sample rate, int32 sample count (-1 = error), float32 samples

#include <dlfcn.h>
#include <dirent.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../../vendor/sherpa-onnx/c-api.h"

typedef const SherpaOnnxOfflineTts *(*CreateFn)(const SherpaOnnxOfflineTtsConfig *);
typedef const SherpaOnnxGeneratedAudio *(*GenerateFn)(const SherpaOnnxOfflineTts *, const char *, const SherpaOnnxGenerationConfig *,
                                                      SherpaOnnxGeneratedAudioProgressCallbackWithArg, void *);
typedef void (*FreeAudioFn)(const SherpaOnnxGeneratedAudio *);
typedef int32_t (*RateFn)(const SherpaOnnxOfflineTts *);

static char *path(const char *dir, const char *name) {
    char *p = malloc(strlen(dir) + strlen(name) + 2);
    sprintf(p, "%s/%s", dir, name);
    return p;
}

static int exists(const char *p) { return access(p, R_OK) == 0; }

/// First file in `dir` ending in `suffix` (Piper voices name their model after the voice).
static char *find(const char *dir, const char *suffix) {
    DIR *d = opendir(dir);
    if (!d) return NULL;
    struct dirent *e;
    char *out = NULL;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name), m = strlen(suffix);
        if (n > m && strcmp(e->d_name + n - m, suffix) == 0) { out = path(dir, e->d_name); break; }
    }
    closedir(d);
    return out;
}

static int write_all(const void *buf, size_t n) {
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: lingveil-tts <runtime> <kind> <model dir> <threads>\n"); return 2; }
    const char *runtime = argv[1], *kind = argv[2], *dir = argv[3];
    char *lib = path(runtime, "libsherpa-onnx-c-api.dylib");
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 3; }
    CreateFn create = (CreateFn)dlsym(h, "SherpaOnnxCreateOfflineTts");
    GenerateFn generate = (GenerateFn)dlsym(h, "SherpaOnnxOfflineTtsGenerateWithConfig");
    FreeAudioFn free_audio = (FreeAudioFn)dlsym(h, "SherpaOnnxDestroyOfflineTtsGeneratedAudio");
    RateFn rate = (RateFn)dlsym(h, "SherpaOnnxOfflineTtsSampleRate");
    if (!create || !generate || !free_audio || !rate) { fprintf(stderr, "sherpa-onnx symbols missing\n"); return 3; }

    SherpaOnnxOfflineTtsConfig c;
    memset(&c, 0, sizeof c);
    c.model.num_threads = atoi(argv[4]) > 0 ? atoi(argv[4]) : 2;
    c.model.provider = "cpu";
    c.max_num_sentences = 1;
    char *espeak = path(dir, "espeak-ng-data");
    if (strcmp(kind, "vits") == 0) {
        c.model.vits.model = find(dir, ".onnx");
        c.model.vits.tokens = path(dir, "tokens.txt");
        c.model.vits.data_dir = espeak;
        c.model.vits.noise_scale = 0.667f; c.model.vits.noise_scale_w = 0.8f; c.model.vits.length_scale = 1.0f;
    } else if (strcmp(kind, "kokoro") == 0) {
        char *m = path(dir, "model.int8.onnx");
        c.model.kokoro.model = exists(m) ? m : path(dir, "model.onnx");
        c.model.kokoro.voices = path(dir, "voices.bin");
        c.model.kokoro.tokens = path(dir, "tokens.txt");
        c.model.kokoro.data_dir = espeak;
        c.model.kokoro.length_scale = 1.0f;
        char *dict = path(dir, "dict");
        if (exists(dict)) c.model.kokoro.dict_dir = dict;
        char *us = path(dir, "lexicon-us-en.txt"), *zh = path(dir, "lexicon-zh.txt");
        if (exists(us) && exists(zh)) {
            char *lex = malloc(strlen(us) + strlen(zh) + 2);
            sprintf(lex, "%s,%s", us, zh);
            c.model.kokoro.lexicon = lex;
        }
    } else if (strcmp(kind, "kitten") == 0) {
        char *m = path(dir, "model.int8.onnx");
        c.model.kitten.model = exists(m) ? m : find(dir, ".onnx");
        c.model.kitten.voices = path(dir, "voices.bin");
        c.model.kitten.tokens = path(dir, "tokens.txt");
        c.model.kitten.data_dir = espeak;
        c.model.kitten.length_scale = 1.0f;
    } else if (strcmp(kind, "supertonic") == 0) {
        c.model.supertonic.duration_predictor = path(dir, "duration_predictor.int8.onnx");
        c.model.supertonic.text_encoder = path(dir, "text_encoder.int8.onnx");
        c.model.supertonic.vector_estimator = path(dir, "vector_estimator.int8.onnx");
        c.model.supertonic.vocoder = path(dir, "vocoder.int8.onnx");
        c.model.supertonic.tts_json = path(dir, "tts.json");
        c.model.supertonic.unicode_indexer = path(dir, "unicode_indexer.bin");
        c.model.supertonic.voice_style = path(dir, "voice.bin");
    } else { fprintf(stderr, "unknown kind %s\n", kind); return 2; }

    const SherpaOnnxOfflineTts *tts = create(&c);
    if (!tts) { fprintf(stderr, "could not load the model\n"); return 4; }
    int32_t sr = rate(tts);
    typedef void (*DestroyFn)(const SherpaOnnxOfflineTts *);
    DestroyFn destroy = (DestroyFn)dlsym(h, "SherpaOnnxDestroyOfflineTts");
    char kokoro_lang[16] = "";
    int is_kokoro = strcmp(kind, "kokoro") == 0;

    char *line = NULL;
    size_t cap = 0;
    struct pollfd p = { .fd = 0, .events = POLLIN };
    for (;;) {
        if (poll(&p, 1, 120000) <= 0) break;   // idle: give the memory back
        ssize_t n = getline(&line, &cap, stdin);
        if (n <= 0) break;
        if (line[n - 1] == '\n') line[n - 1] = 0;
        char *sid = strtok(line, "\t"), *speed = strtok(NULL, "\t"), *lang = strtok(NULL, "\t"), *text = strtok(NULL, "");
        int32_t count = -1;
        const SherpaOnnxGeneratedAudio *a = NULL;
        // Kokoro picks its pronunciation language when it loads: reload when it changes.
        if (is_kokoro && lang && strcmp(lang, kokoro_lang) != 0 && destroy) {
            snprintf(kokoro_lang, sizeof kokoro_lang, "%s", lang);
            c.model.kokoro.lang = kokoro_lang;
            destroy(tts);
            tts = create(&c);
            if (!tts) { fprintf(stderr, "could not load the model\n"); return 4; }
        }
        if (sid && speed && lang && text) {
            SherpaOnnxGenerationConfig g;
            memset(&g, 0, sizeof g);
            g.sid = atoi(sid);
            g.speed = (float)atof(speed);
            g.silence_scale = 0.2f;
            char extra[64];
            snprintf(extra, sizeof extra, "{\"lang\": \"%s\"}", lang);
            g.extra = extra;
            a = generate(tts, text, &g, NULL, NULL);
            if (a && a->n > 0) count = a->n;
        }
        if (write_all(&sr, 4) || write_all(&count, 4)) break;
        if (count > 0 && write_all(a->samples, (size_t)count * 4)) break;
        if (a) free_audio(a);
    }
    return 0;
}
