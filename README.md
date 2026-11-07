# Bearing

A free, open source focus and planning app for the Mac. Set goals, block time for them, focus with timers and music, and get coaching from the AI of your choice. It lives in a window and in your menu bar.

Bearing has no account, subscription or telemetry. Your data stays on your Mac.

Bearing is an independent project inspired by the goal-to-calendar workflow of paid productivity apps. It isn't affiliated with any of them.

## Features

- **Goals:** a personal compass, 12-week seasons, color-coded goals, a weekly trajectory chart with on-track, adjust and off-track bands, and a plan strength score.
- **Menu bar:** your next block and timer, one capture field for tasks, notes and journal entries, today's schedule, tasks and goal progress, plus music and blocking, without opening the window.
- **Week:** drag tasks onto a calendar to time block them. Two-way sync with Apple Calendar and Google Calendar.
- **Tasks:** local tasks, or two-way sync with Todoist using your own API token.
- **Focus:** stopwatch, countdown and Pomodoro timers, a menu bar timer, a floating timer that stays above other apps, and session quality scores.
- **Sound:** 25 bundled tracks, mixable soundscapes (noise and nature), your own music folder, or Spotify and Apple Music control.
- **Blocking:** closes distracting apps and blocks websites during focus, with a delayed exit so you can't quit on impulse.
- **Coach:** direct but kind AI coaching for goals, planning and reviews.
- **Journal and Capture:** daily prompts, plus voice brain dumps of up to 90 minutes transcribed on your Mac. You can paste or import notes from tools like Wispr Flow.
- **Insights:** focus time by goal, session quality and recent sessions.

## Install

Bearing needs macOS 26 or later on Apple Silicon.

Download `Bearing.dmg` from [Releases](https://github.com/tapariapurv/bearing/releases) and drag Bearing to Applications. The app is ad-hoc signed, not notarized, so the first time you open it, go to System Settings > Privacy & Security and choose **Open Anyway**.

## Build from source

You only need the Xcode command line tools, not a paid developer account.

```bash
./build.sh --open   # build, install to ~/Applications, and launch
./build.sh --test   # run the tests
./build.sh --dmg    # build a disk image
```

## Set up the coach

The coach needs a model, which you choose in Settings. To keep it free, run one locally:

- **Local:** [Ollama](https://ollama.com) (the default), LM Studio, or any OpenAI-compatible server URL.
- **Your own API key:** Anthropic, OpenAI, Google Gemini, xAI, Meta Llama, Mistral, DeepSeek, Groq or OpenRouter. Keys are stored in your Keychain. Providers charge for or limit API use on their own terms, and a chat subscription such as Claude or ChatGPT doesn't include an API key.

## Connect Google Calendar

In Settings > Connections, click **Sign in with Google**. Events go directly between your Mac and Google, with no Bearing server. See the [privacy policy](PRIVACY.md).

Google shows an "unverified app" warning until it has reviewed Bearing. Click **Advanced**, then **Go to Bearing**. Sign-ins are limited to 100 people until then.

Building from source? Create a free Desktop app OAuth client in the [Google Cloud console](https://console.cloud.google.com), then put it in `google-client.local` next to `build.sh`:

```
GOOGLE_ID=your-client-id
GOOGLE_SECRET=your-client-secret
```

## Limits

- Website blocking edits `/etc/hosts` through a small helper, which needs your admin password once. A browser using DNS over HTTPS can get around it.
- Because the app is ad-hoc signed, macOS may ask for permissions again after you rebuild it.
- Bearing runs on one Mac only, so there is no sync between devices.

## Music credits

Thank you to the artists. The same list, with source links, is in Settings > Music Credits. Tracks were re-encoded to AAC, and CC BY 4.0 tracks are used under the [Creative Commons Attribution 4.0 license](https://creativecommons.org/licenses/by/4.0/).

| Track | Artist | License | Source |
|---|---|---|---|
| Ascending the Vale | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| At Rest | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Clean Soul | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Dreamer | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Heartbreaking | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Long Note Four | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Long Note Three | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Lost Frontier | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Meditation Impromptu 01 | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Rising Tide | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Sovereign Quarter | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| Touching Moments Two - Higher | Kevin MacLeod (incompetech.com) | CC BY 4.0 | [link](https://incompetech.com) |
| 2 Hour Delay | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/winter-lofi/2-hour-delay-1/) |
| Anxiety | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-1/anxiety/) |
| April Showers | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/spring-at-last-lofi-tape/april-showers/) |
| Boredom | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-1/boredom/) |
| Deja Vu | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-1/deja-vu/) |
| Fire Place | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/winter-lofi/fire-place/) |
| First Snow.mp3 | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/winter-lofi/first-snowmp3/) |
| Kids | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/spring-at-last-lofi-tape/kids/) |
| Love | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/only-in-the-milky-way-part-1/love-1/) |
| Sense Of Purpose | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/spring-at-last-lofi-tape/sense-of-purpose/) |
| Snow Drift | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/winter-lofi/snow-drift/) |
| Spring At Last | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/spring-at-last-lofi-tape/spring-at-last/) |
| Winter Blues | HoliznaCC0 | CC0 1.0 | [link](https://freemusicarchive.org/music/holiznacc0/winter-lofi/winter-blues/) |

## License

The code is under the [MIT License](LICENSE). The bundled music keeps the licenses listed above.
