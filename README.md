# ESP32 LED Flutter

A simple Flutter app to control an ESP32 RGB LED via Bluetooth.
<img width="1088" height="1445" alt="Jul 1, 2026, 11_46_13 AM" src="https://github.com/user-attachments/assets/b49c2269-c707-48f9-ba79-59fbcd8a489b" />


## Features

- Scan and connect to ESP32 via BLE
- Color picker
- Brightness control
- Effects: Solid, Rainbow, Breathe, Party
- Quick color presets
- ON / OFF

## How to Use

1. Flash the ESP32 code (in `/esp32` folder) using PlatformIO
2. Open the Flutter app (`/esp32_control_flutter`)
3. Run `flutter run`
4. Scan → Connect → Control your LED!

Built with Flutter + flutter_blue_plus.
