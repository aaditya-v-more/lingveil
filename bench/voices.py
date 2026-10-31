"""Voice benchmark: speed and clarity of every read-aloud engine, measured the same way.

Each engine speaks the sentences in bench/speak/<lang>.txt. Speed is the real-time factor
(seconds to synthesize per second of audio, after the model is loaded). Clarity is how well
a speech recognizer (whisper.cpp, large-v3-turbo) transcribes the audio: the character
error rate against the sentence it was asked to say. Results go to bench/voices.json;
python3 bench/rate.py turns them into ratings.

usage: python3 bench/voices.py --whisper <ggml model> --runtime <sherpa-onnx lib dir>
       [--models <dir with narration models>] [--helper build/Lingveil.app/Contents/Helpers/lingveil-tts]
"""
import argparse, array, json, os, struct, subprocess, tempfile, time, unicodedata, urllib.request, wave

here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--whisper", required=True)
ap.add_argument("--runtime")
ap.add_argument("--models", default=os.path.expanduser("~/Library/Application Support/Lingveil/Voices"))
ap.add_argument("--helper", default=os.path.join(here, "..", "build/Lingveil.app/Contents/Helpers/lingveil-tts"))
args = ap.parse_args()
tmp = tempfile.mkdtemp()
catalog = json.load(open(os.path.join(here, "..", "shared", "voices.json"), encoding="utf-8"))


def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if c.isalnum())


def cer(hyp, ref):
    h, r = norm(hyp), norm(ref)
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)] / max(1, len(r))


def transcribe(path, lang):
    out = subprocess.run(["whisper-cli", "-m", args.whisper, "-l", lang, "-nt", "-np", "-f", path],
                         capture_output=True, text=True).stdout
    return " ".join(out.split())


def duration(path):
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def write_wav(path, sr, floats):
    pcm = array.array("h", (int(max(-1, min(1, x)) * 32767) for x in floats))
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())


def apple(text, voice, out):
    subprocess.run(["say", "-v", voice, "-o", out, "--data-format=LEI16@22050", text], check=True)


def google(text, voice, out):
    req = urllib.request.Request("http://127.0.0.1:5591/speak", json.dumps({"text": text, "voice": voice}).encode(),
                                 {"Content-Type": "application/json"})
    open(out, "wb").write(urllib.request.urlopen(req, timeout=60).read())


class Model:
    def __init__(self, m):
        d = os.path.join(args.models, m["id"])
        self.p = subprocess.Popen([args.helper, args.runtime, m["kind"], d, "4"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.m = m

    def say(self, text, lang, out):
        sid = self.m["speakers"].get(lang, self.m["speakers"].get("default", 0))
        self.p.stdin.write(f"{sid}\t1.0\t{lang}\t{text}\n".encode()); self.p.stdin.flush()
        sr, n = struct.unpack("<ii", self.p.stdout.read(8))
        if n <= 0:
            raise RuntimeError("no audio")
        write_wav(out, sr, array.array("f", self.p.stdout.read(n * 4)))

    def close(self):
        self.p.stdin.close(); self.p.wait()


def run(name, lang, speak):
    sentences = [l.strip() for l in open(os.path.join(here, "speak", f"{lang}.txt"), encoding="utf-8") if l.strip()]
    speak(sentences[0], os.path.join(tmp, "warm.wav"))   # load the model / service first
    spent, audio, errors = 0.0, 0.0, []
    for i, s in enumerate(sentences):
        out = os.path.join(tmp, f"{name}-{lang}-{i}.wav")
        t = time.time(); speak(s, out); spent += time.time() - t
        audio += duration(out)
        errors.append(cer(transcribe(out, lang), s))
    r = {"rtf": round(spent / audio, 3), "cer": round(sum(errors) / len(errors), 4)}
    print(f"{name:22} {lang}  RTF {r['rtf']:.2f}  CER {r['cer'] * 100:5.1f}%", flush=True)
    return r


results = {}
for eid, voice in catalog["apple"].items():
    results.setdefault("apple", {})[eid] = run("apple", eid, lambda s, o, v=voice: apple(s, v, o))
for lang, voice in catalog["google"].items():
    try:
        results.setdefault("google", {})[lang] = run("google", lang, lambda s, o, v=voice: google(s, v, o))
    except OSError:
        print("google voices not running; skipped")
        break
if args.runtime:
    for m in catalog["models"]:
        if not os.path.isdir(os.path.join(args.models, m["id"])):
            continue
        model = Model(m)
        for lang in m["benchLanguages"]:
            results.setdefault(m["id"], {})[lang] = run(m["id"], lang, lambda s, o, l=lang: model.say(s, l, o))
        model.close()
json.dump(results, open(os.path.join(here, "voices.json"), "w", encoding="utf-8"), indent=2)
