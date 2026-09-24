# Grok

A watch-only Apple Watch app. Tap the fluffy face, talk, and Grok answers in one or two spoken sentences. The face loops a short clip for idle, listening, thinking, and speaking.

Chat uses the xAI API model `grok-4.7`. The four clips were generated once with `grok-imagine-video-1.5` from `avatar.jpg` and are bundled in the app.

## Run

1. Create `.env` in the project root:

   ```
   GROK_API_KEY=your_key_here
   ```

2. Write the key into the app (this also regenerates clips if they are missing):

   ```
   python3 scripts/generate_clips.py
   ```

   That creates `GrokWatch/Secrets.swift`, which is gitignored. The script needs Python 3 with Pillow and certifi.

3. Open `GrokWatch.xcodeproj` in Xcode.
4. Select the **GrokWatch** scheme.
5. For the simulator, pick a watchOS simulator such as **Apple Watch Series 11 (46mm)** and press Run. The simulator uses the on-screen keyboard instead of the microphone.
6. For a real watch, pair it with your iPhone, connect the iPhone to this Mac, and turn on Developer Mode on the watch under **Settings > Privacy & Security**. Choose the physical watch as the run destination, sign with your Personal Team, and press Run. A free Apple ID install expires after about 7 days.

The watch needs Wi-Fi, or the iPhone nearby, to reach Grok.

## Clips

`scripts/generate_clips.py` reads `GROK_API_KEY` from `.env`, crops `avatar.jpg`, and saves:

- `GrokWatch/Media/idle.mp4`
- `GrokWatch/Media/listening.mp4`
- `GrokWatch/Media/thinking.mp4`
- `GrokWatch/Media/speaking.mp4`

Clips that already exist are left alone. Delete a file to generate it again. Each new clip spends API credits.

## Secrets

`.env` and `GrokWatch/Secrets.swift` are gitignored. Do not commit them. The key is embedded in the personal build so the watch can call Grok directly.
