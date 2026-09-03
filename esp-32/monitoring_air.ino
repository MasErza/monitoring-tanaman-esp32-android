#include <WiFi.h>
#include <WebServer.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <DHT.h> // Tambahan Library DHT22
#include "config.h"

// ===== WIFI =====
const char* ssid = "WIFI_SSID";
const char* password = "WIFI_PASSWORD";

// ===== SERVER =====
WebServer server(80);

// ===== PIN =====
#define SENSOR_PIN 34
#define RELAY_PIN 23
#define DHTPIN 4      // Gunakan Pin 4 (GPIO 4) untuk Data DHT22
#define DHTTYPE DHT22 // Tipe Sensor

// Banyak modul relay bekerja active LOW
#define RELAY_ON HIGH
#define RELAY_OFF LOW

// ===== KOMPONEN =====
LiquidCrystal_I2C lcd(0x27, 16, 2);
DHT dht(DHTPIN, DHTTYPE);

// ===== VAR SENSOR =====
int kelembabanTanah = 0;
float suhu = 0.0;
float kelembabanUdara = 0.0;

String statusTanah = "";
String statusSuhu = "";
String statusPompa = "Monitoring";

// ===== MODE POMPA & TIMER =====
bool manualMode = false;
bool manualRelayState = false;

bool isWatering = false;
unsigned long wateringEndTime = 0;
unsigned long lastUpdate = 0; // Timer pengganti delay() di void loop

// ===== KALIBRASI & BATAS =====
int nilaiKering = 3000;
int nilaiBasah = 1200;
float batasSuhuPanas = 30.0; 

// ===== TIMER INIT =====
unsigned long startTime;
bool systemReady = false;
String ipAddress = "";

// ===== API (DIUPDATE UNTUK FLUTTER) =====
void handleData() {
  String json = "{";
  json += "\"kelembaban_tanah\":" + String(kelembabanTanah) + ",";
  json += "\"suhu\":" + String(suhu, 1) + ",";
  json += "\"kelembaban_udara\":" + String(kelembabanUdara, 1) + ",";
  json += "\"status_tanah\":\"" + statusTanah + "\",";
  json += "\"status_suhu\":\"" + statusSuhu + "\",";
  json += "\"status_pompa\":\"" + statusPompa + "\",";
  json += "\"mode\":\"" + String(manualMode ? "Manual" : "Otomatis") + "\",";
  json += "\"status_alat\":\"Online\",";
  json += "\"ip\":\"" + ipAddress + "\"";
  json += "}";

  server.send(200, "application/json", json);
}

void handleRelayOn() {
  manualMode = true;
  manualRelayState = true;
  digitalWrite(RELAY_PIN, RELAY_ON);
  statusPompa = "Manual ON";
  server.send(200, "text/plain", "Relay ON");
}

void handleRelayOff() {
  manualMode = true;
  manualRelayState = false;
  digitalWrite(RELAY_PIN, RELAY_OFF);
  statusPompa = "Manual OFF";
  server.send(200, "text/plain", "Relay OFF");
}

void handleRelayAuto() {
  manualMode = false;
  isWatering = false; // Reset state timer
  digitalWrite(RELAY_PIN, RELAY_OFF);
  statusPompa = "Monitoring";
  server.send(200, "text/plain", "Mode Otomatis");
}

// ===== SETUP =====
void setup() {
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_OFF);
  delay(200);

  Serial.begin(115200);

  lcd.init();
  lcd.backlight();
  dht.begin(); // Inisialisasi DHT22

  // ===== WIFI =====
  lcd.setCursor(0, 0);
  lcd.print("Connecting WiFi");

  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
  }

  ipAddress = WiFi.localIP().toString();

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("IP:");
  lcd.setCursor(0, 1);
  lcd.print(ipAddress);

  delay(3000);

  // ===== ROUTES =====
  server.on("/data", handleData);
  server.on("/relay/on", handleRelayOn);
  server.on("/relay/off", handleRelayOff);
  server.on("/relay/auto", handleRelayAuto);

  server.begin();
  startTime = millis();
}

// ===== LOOP =====
void loop() {
  server.handleClient();

  // ===== INIT DELAY 15 DETIK =====
  if (!systemReady) {
    if (millis() - startTime < 15000) {
      return; // Tunggu sensor stabil
    } else {
      systemReady = true;
      lcd.clear();
    }
  }

  // ===== BACA SENSOR & UPDATE LCD SETIAP 2 DETIK =====
  if (millis() - lastUpdate >= 2000 && systemReady) {
    lastUpdate = millis();

    // 1. Baca Soil Moisture
    int nilaiAnalog = analogRead(SENSOR_PIN);
    kelembabanTanah = map(nilaiAnalog, nilaiKering, nilaiBasah, 0, 100);
    kelembabanTanah = constrain(kelembabanTanah, 0, 100);

    // 2. Baca Suhu DHT22
    float h = dht.readHumidity();
    float t = dht.readTemperature();
    if (!isnan(h) && !isnan(t)) {
      kelembabanUdara = h;
      suhu = t;
    }

    // 3. Status Tanah
    if (kelembabanTanah < 40) {
      statusTanah = "Kering";
    } else if (kelembabanTanah < 70) {
      statusTanah = "Lembab"; // Sesuai aturan baru
    } else {
      statusTanah = "Basah";
    }

    // 4. Status Suhu
    if (suhu > batasSuhuPanas) {
      statusSuhu = "Panas";
    } else {
      statusSuhu = "Normal";
    }

    // 5. Update LCD (Baris 1: Tanah & Suhu)
    lcd.setCursor(0, 0);
    lcd.print("T:"); lcd.print(kelembabanTanah); lcd.print("% ");
    lcd.print("S:"); lcd.print(suhu, 0); lcd.print("C  ");

    // Baris 2: Status Pompa
    lcd.setCursor(0, 1);
    lcd.print(statusPompa);
    lcd.print("                "); // Clear sisa karakter

    // 6. Debug Serial
    Serial.println("Soil: " + String(kelembabanTanah) + "% (" + statusTanah + ")");
    Serial.println("Suhu: " + String(suhu) + "C (" + statusSuhu + ")");
    Serial.println("Pompa: " + statusPompa);
    Serial.println("--------------------");
  }

  // ===== LOGIKA OTOMATISASI PENYIRAMAN =====
  if (manualMode) {
    // Mode Manual Overide
    if (manualRelayState) {
      digitalWrite(RELAY_PIN, RELAY_ON);
      statusPompa = "Manual ON";
    } else {
      digitalWrite(RELAY_PIN, RELAY_OFF);
      statusPompa = "Manual OFF";
    }
  } else {
    // Mode Otomatis
    if (!isWatering) {
      unsigned long durasiSiram = 0;

      // ATURAN PENYIRAMAN BARU
      if (statusTanah == "Kering" && statusSuhu == "Panas") durasiSiram = 60000;
      else if (statusTanah == "Kering" && statusSuhu == "Normal") durasiSiram = 40000;
      else if (statusTanah == "Lembab" && statusSuhu == "Panas") durasiSiram = 30000;
      else if (statusTanah == "Lembab" && statusSuhu == "Normal") durasiSiram = 15000;
      // Kategori Basah otomatis 0 (tidak masuk if)

      if (durasiSiram > 0) {
        isWatering = true;
        wateringEndTime = millis() + durasiSiram;
        digitalWrite(RELAY_PIN, RELAY_ON);
      } else {
        digitalWrite(RELAY_PIN, RELAY_OFF);
        statusPompa = "Monitoring";
      }
    } else {
      // Sedang dalam proses menyiram
      if (millis() >= wateringEndTime) {
        isWatering = false;
        digitalWrite(RELAY_PIN, RELAY_OFF);
        statusPompa = "Monitoring";
      } else {
        // Tampilkan sisa detik di LCD dan API
        unsigned long sisaDetik = (wateringEndTime - millis()) / 1000;
        statusPompa = "Nyiram:" + String(sisaDetik) + "s";
      }
    }
  }
}