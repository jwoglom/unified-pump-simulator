# unified-pump-simulator
The MacOS unified pump manager

## Supported pumps
- Dana-i & DanaRS firmware 3 -> [DanaKit](https://github.com/bastiaanv/DanaKit)
- Medtrum (200u & 300u) -> [MedtrumKit](https://github.com/jbr7rr/MedtrumKit)
- Tandem Mobi -> [TandemKit](https://github.com/jwoglom/TandemKit), through [faketandem](https://github.com/jwoglom/faketandem) (see below)
- MiniMed Flex -> [FlexKit](https://github.com/bastiaanv/FlexKit)

## How to get started

Clone the repo to your Mac & open the workspace file:

```sh
git clone https://github.com/bastiaanv/unified-pump-simulator
xed ./unified-pump-simulator
```

Once XCode has opened, double check the signing & capability settings.
After that, use the play button to start the application.
Make sure to give the application the permission for Bluetooth.

## Tandem: faketandem over real Bluetooth

The Tandem tab does not model the pump itself. It puts
[faketandem](https://github.com/jwoglom/faketandem), the Go emulator that TandemKit's own
integration tests run against, on the air: the Mac advertises as the pump, and every
subscription, write and read the phone makes is forwarded over faketandem's virtual GATT link,
whose notifications come back the same way. Pairing (JPAKE), signed control messages, the history
log, qualifying events, Control-IQ, alarms, cartridge procedures and faketandem's fault injection all
work as they do against the emulator directly, and the phone's app runs unchanged.

Start faketandem first, from its repository:

```sh
go run . -transport virtual -q
```

It listens for the link on `127.0.0.1:8081` and serves its HTTP API and web UI on
`http://127.0.0.1:8080`, which the tab also uses: the status panel polls `/api/state`, the buttons
set the pairing state, start a bolus or temp basal on the pump, suspend, raise an occlusion and so
on, and the sliders set the reservoir and battery. Everything else is in faketandem's web UI
("Open faketandem web UI"). Other addresses go in the app's environment as `FAKETANDEM_GATT`
(`host:port`) and `FAKETANDEM_API_URL`, the variables TandemKit's harness reads too.

faketandem starts `NotDiscoverable` and refuses connections until a pairing state is set; the tab
waits for that ("Pairing state: PairStep2"), then advertises. The pairing code is faketandem's
(`123456` unless changed), shown in the pump notes.

Two things CoreBluetooth cannot do, and how the tab stands in for them:

- A peripheral cannot advertise manufacturer data, where TandemKit reads a pump's pairing step. The
  tab advertises faketandem's name with `Simulator` before the serial (`Tandem Mobi Simulator 123`),
  which TandemKit takes as a simulator ready for its code.
- A peripheral cannot end a connection. When faketandem drops the link (a fault, or being made
  `NotDiscoverable`), the tab withdraws its services, which fails the phone's next request, and
  publishes them again once faketandem is back.

The phone's notification size is passed on to faketandem (`PUT /api/transport`), so responses arrive
in one notification as from a Mobi, rather than in 20-byte fragments.
