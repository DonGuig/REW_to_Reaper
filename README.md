# REW → Reaper EQ

A ReaScript that pulls the EQ filters from [Room EQ Wizard (REW)](https://www.roomeqwizard.com) through its local API and writes them into an EQ plugin in [REAPER](https://www.reaper.fm). It supports:

- **ReaEQ** (Cockos, built into REAPER)
- **FabFilter Pro-Q 3**
- **FabFilter Pro-Q 4**

Typical use: measure a speaker or room in REW, let REW design the correction (or design it by hand), then press **Apply** in REAPER. The filters land in your EQ instance with their frequency, gain, Q and type, converted to each plugin's own Q convention so the result matches REW's predicted response.

The script is a single Lua file. It needs no extensions and no extra libraries.

---

## Requirements

- **REAPER** (recent version; tested on macOS).
- **REW 5.40 or later** with its **API running**: *Preferences → API → Start*, or launch REW with the `-api` argument. The default port is 4735.
- **curl**, which ships with macOS and Windows 10/11.
- For CLAP plugins, **an audio device must be selected in REAPER** (see [Troubleshooting](#troubleshooting)).

In REW, set the measurement's **Equaliser** to **Generic** (or *Equalizer APO*) so that filters are plain peaking, shelf and high/low-pass types.

## Installation

1. Download `REW_to_EQ.lua`.
2. In REAPER: **Actions → Show action list → New action → Load ReaScript…** and select the file.
3. Optionally assign a keyboard shortcut or a toolbar button to the action.

## Usage

Run the action. A window opens:

| Control | What it does |
|---|---|
| **Track** | Selected track, master track, or any track in the project. A track with a unique name is remembered by name, so reordering tracks doesn't break the setting. |
| **EQ plugin** | The first ReaEQ / Pro-Q on the track, any FX in the track's chain, or *Type a name…* (part of the FX name). Tip: rename instances in the FX chain (e.g. "EQ Left") to target them reliably. |
| **If no EQ found** | Don't insert anything, or insert ReaEQ / Pro-Q 3 / Pro-Q 4 on the track. |
| **REW measurement** | The measurement currently selected in REW, or any measurement from REW's list. The list is fetched from REW when you open the menu. |
| **REW address** | IP and port of the computer running REW. Default: this computer, port 4735. See [REW on another computer](#rew-on-another-computer). |
| **Disable unused bands** | Switches off EQ bands that the REW filter set doesn't use. |
| **Dry run** | Writes nothing. The console lists the filters REW returned, how each will be translated, and the plugin's parameters. |

- **Apply** (or **Enter**) writes the filters. The window stays open, so you can change the EQ in REW and apply again.
- **Close** (or **Esc**) closes the window.
- Every write is a single undo step in REAPER.
- All choices and the window position are remembered between runs.

A summary is printed to the ReaScript console after each run, including any notes about filters that couldn't be reproduced exactly.

### REW on another computer

REAPER and REW don't need to run on the same machine. For example, REW can run on your laptop at the measurement position while REAPER runs on the playback machine.

1. **On the REW computer**, start REW with its API open to the network:
   - macOS: `open -a REW.app --args -api -host 0.0.0.0`
   - Windows: `"C:\Program Files\REW\roomeqwizard.exe" -api -host 0.0.0.0`

   Without `-host 0.0.0.0`, REW's API only answers requests from its own computer.
2. **Allow incoming TCP connections on port 4735** in that computer's firewall. On macOS you may simply get an "accept incoming connections" prompt for REW.
3. **In the script's window**, click *REW address* and enter the REW computer's IP address, e.g. `192.168.1.20`.

> **Security:** REW's API has no password. Once it is open to the network, anyone who can reach that computer can control REW. Only do this on a trusted network, such as your show or studio network. Alternatively, keep REW private and use an SSH tunnel from the REAPER computer: `ssh -N -L 4735:localhost:4735 user@rew-computer`. Then leave *REW address* on *This computer*.

### One-click variants

To skip the window, for example to have one action per speaker:

1. Make a copy of the script.
2. Set `ASK_EACH_TIME = false` at the top.
3. Fill in the `PRESET` table (track, FX, measurement, etc.).

Running that copy applies the filters straight away.

---

## How the filters are translated

REW's API reports Q in **RBJ** convention, whatever Q format the REW EQ window displays. *Classic Q* and *Symmetric Q* in REW's Configurable PEQ only relabel the same filter. The script converts that RBJ Q to each plugin's convention.

| REW filter | FabFilter Pro-Q 3 / 4 | ReaEQ |
|---|---|---|
| Peaking (PK) | Bell, **Q × √2** | Band, bandwidth in octaves: `BW = 2/ln2 · asinh(1/(2Q))` |
| Low / high shelf (LS, HS, and Q variants) | Low/High Shelf, **Q × √2**, 12 dB/oct | Shelf, **BW = √(1/S)**, where S is the RBJ shelf slope derived from Q and gain. REW's standard shelf (Q 0.707) = **BW 1.0** |
| High / low pass (HP, LP, and Q variants) | Low/High Cut, **Q × √2**, 12 dB/oct (Butterworth = Q 1.0) | High/Low Pass, same octave formula as bells (Butterworth = **BW 1.9**) |
| 1st-order HP / LP | Low/High Cut, 6 dB/oct | *not supported* (skipped) |
| Notch, band pass | Notch, Band Pass | Notch, Band Pass |

The bell, shelf and high/low-pass conversions were **checked by measurement**. Impulse responses rendered through each plugin were imported into REW and overlaid on REW's predicted filter response. ReaEQ's shelves were fitted to within 0.001 dB of an ideal RBJ shelf.

Plugin values are set by reading the plugin's own displayed values (Hz, dB, Q, shape names) rather than hard-coded parameter curves. This keeps the script independent of each plugin's internal parameter scaling.

---

## Limitations

**General**
- Only the three plugins above are supported.
- Notch and band-pass translations follow the same logic but haven't been checked by measurement.
- All-pass filters are not supported.
- REW's digital (RBJ) filters get slightly "cramped" near Nyquist, while Pro-Q follows the analog shape. Above a few kHz at 44.1/48 kHz, Pro-Q's bells come out a little wider than REW predicts. This is negligible for typical room and speaker correction, and much smaller at 96 kHz.
- The script was developed and tested on macOS. Windows should work, since it uses the system's `curl`, but hasn't been tested.

**ReaEQ**
- **Bands can't be added by script.** If REW has more filters than the ReaEQ instance has bands, the script stops and tells you how many to add. Click *Add band* in ReaEQ and apply again.
- **1st-order (6 dB/oct) high/low-pass filters are skipped.** ReaEQ's high/low-pass filters are 2nd order.
- **6 dB/oct shelves are approximated** by a gentle 2nd-order shelf.
- **Shelves steeper than about Q 0.78** (at ±6 dB; the limit shifts slightly with gain) can't be reproduced. ReaEQ clamps its shelf bandwidth at about **0.913 octave**, and any lower value gives the same curve. The script sets 0.913 and prints a note. Use Pro-Q for those filters.

**Pro-Q**
- Up to 24 bands, which is Pro-Q's own limit. Extra REW filters are ignored with a note.
- Gain-Q interaction can be on or off; it doesn't affect values entered by the script.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "REW's API is not reachable at …" | REW isn't running, or its API isn't started: *Preferences → API → Start*, or launch REW with `-api`. If REW is on another computer, launch it with `-api -host 0.0.0.0`, check the IP in *REW address*, and allow port 4735 in its firewall. Opening `http://<REW-IP>:4735` in a browser on the REAPER computer should show REW's API documentation. |
| "REW is running, but it has no measurements" | Make a measurement or load an `.mdat` file in REW, set up its EQ filters, then apply again. |
| "REW has no measurement N" | The measurement chosen in the window no longer exists in REW (e.g. it was removed, or a different file is loaded). Pick one again in *REW measurement*. |
| "Could not read REW's selected measurement" | REW has several measurements and none is selected. Select one in REW, or pick one in the window. |
| A CLAP plugin doesn't change (VST3/AU works) | Select an audio device in REAPER (*Preferences → Audio → Device*). REAPER applies CLAP parameter changes through its audio engine, which doesn't run without a device. Starting the transport isn't needed. |
| Filters don't match REW's prediction | Make sure REW's equaliser is set to *Generic*. Run a **Dry run** and check the console: each REW filter type is listed with its translation. |
| A REW filter is reported as "not recognised" | Run a dry run and open an issue with the console output, including the exact REW type name. |
| ReaEQ: "this ReaEQ has N bands" | Add bands in ReaEQ (*Add band*) and apply again. |

### Verifying the result yourself

1. Put a one-sample impulse WAV on the EQ'd track and render it (32-bit float).
2. In REW: *File → Import → Impulse response*.
3. In REW's EQ window, click *Generate filters measurement*.
4. Overlay the two responses. They should coincide.

---

## License

[MIT](LICENSE) © 2026 Guillaume Couturier

REW, REAPER, ReaEQ, FabFilter and Pro-Q are trademarks of their respective owners. This project is not affiliated with or endorsed by them.
