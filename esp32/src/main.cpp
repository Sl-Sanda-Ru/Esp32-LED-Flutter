#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>

#define NEO_PIN   48
#define NEO_COUNT 1

#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

static const char* SERVICE_UUID = "6E400001-B5A4-F393-E0A9-E50E24DCCA9E";
static const char* CHAR_UUID_RX = "6E400002-B5A4-F393-E0A9-E50E24DCCA9E";
static const char* CHAR_UUID_TX = "6E400003-B5A4-F393-E0A9-E50E24DCCA9E";

Adafruit_NeoPixel strip(NEO_COUNT, NEO_PIN, NEO_GRB + NEO_KHZ800);

NimBLECharacteristic* pTxChar = nullptr;
bool bleConnected = false;

uint8_t ledR = 0, ledG = 255, ledB = 0;
uint8_t ledBri = 80;
bool    ledOn  = false;

enum Effect { SOLID, RAINBOW, BREATHE, PARTY };
Effect currentEffect = SOLID;

uint16_t      rainbowHue  = 0;
uint8_t       breatheVal  = 0;
bool          breatheDir  = true;
unsigned long lastStepMs  = 0;

static const uint32_t partyCols[] = {
  0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF,
  0xFF00FF, 0xFF8000, 0x8000FF, 0xFFFFFF, 0xFF1493,
  0x39FF14, 0x0080FF, 0xFF4500, 0x00FF80, 0xFFD700,
  0x9400D3, 0x00BFFF, 0xFF69B4, 0x7FFF00, 0xDC143C,
};
static const int NUM_PARTY = sizeof(partyCols) / sizeof(partyCols[0]);

void showColor(uint8_t r, uint8_t g, uint8_t b, uint8_t bri) {
  strip.setBrightness(bri);
  strip.setPixelColor(0, strip.Color(r, g, b));
  strip.show();
  digitalWrite(LED_BUILTIN, HIGH);
}

void turnOff() {
  strip.setPixelColor(0, 0);
  strip.show();
  digitalWrite(LED_BUILTIN, LOW);
}

void parseCommand(String raw) {
  raw.trim();
  String cmd = raw;
  cmd.toUpperCase();

  if (cmd.length() == 7 && cmd[0] == '#') {
    long hex = strtol(cmd.c_str() + 1, nullptr, 16);
    ledR = (hex >> 16) & 0xFF;
    ledG = (hex >> 8)  & 0xFF;
    ledB =  hex        & 0xFF;
    ledOn = true;
    currentEffect = SOLID;
    showColor(ledR, ledG, ledB, ledBri);

  } else if (cmd.startsWith("RGB,")) {
    int a = cmd.indexOf(',', 4);
    int b = cmd.indexOf(',', a + 1);
    if (a > 0 && b > 0) {
      ledR = (uint8_t)constrain(cmd.substring(4, a).toInt(), 0, 255);
      ledG = (uint8_t)constrain(cmd.substring(a + 1, b).toInt(), 0, 255);
      ledB = (uint8_t)constrain(cmd.substring(b + 1).toInt(), 0, 255);
      ledOn = true;
      currentEffect = SOLID;
      showColor(ledR, ledG, ledB, ledBri);
    }

  } else if (cmd.startsWith("BRI,")) {
    ledBri = (uint8_t)constrain(cmd.substring(4).toInt(), 0, 255);
    if (ledOn && currentEffect == SOLID) showColor(ledR, ledG, ledB, ledBri);

  } else if (cmd == "OFF") {
    ledOn = false;
    currentEffect = SOLID;
    turnOff();

  } else if (cmd == "ON") {
    ledOn = true;
    currentEffect = SOLID;
    showColor(ledR, ledG, ledB, ledBri);

  } else if (cmd == "RAINBOW") {
    currentEffect = RAINBOW;
    ledOn = true;

  } else if (cmd == "PARTY") {
    currentEffect = PARTY;
    ledOn = true;

  } else if (cmd.startsWith("BREATHE,")) {
    int a  = cmd.indexOf(',', 8);
    int b2 = cmd.indexOf(',', a + 1);
    if (a > 0 && b2 > 0) {
      ledR = (uint8_t)constrain(cmd.substring(8, a).toInt(), 0, 255);
      ledG = (uint8_t)constrain(cmd.substring(a + 1, b2).toInt(), 0, 255);
      ledB = (uint8_t)constrain(cmd.substring(b2 + 1).toInt(), 0, 255);
      breatheVal = 0;
      breatheDir = true;
      currentEffect = BREATHE;
      ledOn = true;
    }
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*) override {
    bleConnected = true;
    Serial.println("BLE client connected");
  }
  void onDisconnect(NimBLEServer*) override {
    bleConnected = false;
    Serial.println("BLE client disconnected");
    NimBLEDevice::startAdvertising();
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChar) override {
    std::string val = pChar->getValue();
    if (!val.empty()) {
      Serial.print("RX: "); Serial.println(val.c_str());
      parseCommand(String(val.c_str()));
    }
  }
};

void runEffects() {
  if (!ledOn) return;
  unsigned long now = millis();

  switch (currentEffect) {
    case RAINBOW:
      if (now - lastStepMs >= 8) {
        strip.setBrightness(100);
        strip.setPixelColor(0, strip.gamma32(strip.ColorHSV(rainbowHue)));
        strip.show();
        rainbowHue += 256;
        lastStepMs = now;
      }
      break;

    case BREATHE:
      if (now - lastStepMs >= 12) {
        strip.setBrightness(breatheVal);
        strip.setPixelColor(0, strip.Color(ledR, ledG, ledB));
        strip.show();
        breatheVal = breatheDir
          ? (uint8_t)min(255, (int)breatheVal + 5)
          : (uint8_t)max(0,   (int)breatheVal - 5);
        if (breatheVal == 255) breatheDir = false;
        if (breatheVal == 0)   breatheDir = true;
        lastStepMs = now;
      }
      break;

    case PARTY: {
      if (now - lastStepMs >= 60) {
        static bool partyOn = false;
        if (!partyOn) {
          uint32_t c = partyCols[random(NUM_PARTY)];
          strip.setBrightness(180);
          strip.setPixelColor(0, c);
          strip.show();
        } else {
          turnOff();
        }
        partyOn = !partyOn;
        lastStepMs = now;
      }
      break;
    }

    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  strip.begin();
  turnOff();
  randomSeed(esp_random());

  NimBLEDevice::init("ESP32-LED");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  NimBLEServer* pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pService = pServer->createService(SERVICE_UUID);

  pTxChar = pService->createCharacteristic(
    CHAR_UUID_TX,
    NIMBLE_PROPERTY::NOTIFY
  );

  NimBLECharacteristic* pRxChar = pService->createCharacteristic(
    CHAR_UUID_RX,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pRxChar->setCallbacks(new RxCallbacks());

  pService->start();

  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setScanResponse(true);
  pAdv->start();

  Serial.println("BLE advertising as 'ESP32-LED'");
}

void loop() {
  runEffects();
}