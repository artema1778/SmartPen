import SwiftUI
import Speech
import AVFoundation
import CoreBluetooth
import Combine

@main
struct SmartPenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Bluetooth

final class BluetoothManager: NSObject, ObservableObject,
                              CBCentralManagerDelegate,
                              CBPeripheralDelegate {

    @Published var devices: [CBPeripheral] = []
    @Published var status = "Bluetooth запускается"
    @Published var connectedName = "Нет подключения"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writable: CBCharacteristic?

    private var chunks: [Data] = []
    private var writeType: CBCharacteristicWriteType = .withResponse

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status = central.state == .poweredOn
            ? "Bluetooth включён"
            : "Включи Bluetooth на iPhone"
    }

    func scan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth недоступен"
            return
        }

        devices.removeAll()
        status = "Идёт поиск BLE устройств..."
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        if !devices.contains(where: {
            $0.identifier == peripheral.identifier
        }) {
            devices.append(peripheral)
        }
    }

    func connect(_ device: CBPeripheral) {
        central.stopScan()
        peripheral = device
        device.delegate = self
        status = "Подключение..."
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name ?? "BLE устройство"
        status = "Поиск Bluetooth характеристик..."
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Не удалось подключиться"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedName = "Нет подключения"
        writable = nil
        status = "Bluetooth отключён"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil else {
            status = "Ошибка поиска служб"
            return
        }

        peripheral.services?.forEach {
            peripheral.discoverCharacteristics(nil, for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return }

        for characteristic in service.characteristics ?? [] {
            let properties = characteristic.properties

            if properties.contains(.write) ||
               properties.contains(.writeWithoutResponse) {
                writable = characteristic
                status = "Плата готова к передаче текста"
                return
            }
        }

        status = "Не найдена характеристика для отправки"
    }

    func send(_ text: String) {
        guard let peripheral, let characteristic = writable else {
            status = "Сначала подключи BLE устройство"
            return
        }

        guard !text.isEmpty else { return }

        let data = Data((text + "\n").utf8)

        writeType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse

        let maxLength = peripheral.maximumWriteValueLength(
            for: writeType
        )

        guard maxLength > 0 else {
            status = "Невозможно отправить данные"
            return
        }

        chunks.removeAll()

        var offset = 0

        while offset < data.count {
            let end = min(offset + maxLength, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }

        status = "Передача текста..."
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard let peripheral, let characteristic = writable else {
            return
        }

        if writeType == .withResponse {
            guard let chunk = chunks.first else {
                status = "Текст отправлен"
                return
            }

            peripheral.writeValue(
                chunk,
                for: characteristic,
                type: .withResponse
            )
        } else {
            while !chunks.isEmpty &&
                  peripheral.canSendWriteWithoutResponse {

                let chunk = chunks.removeFirst()

                peripheral.writeValue(
                    chunk,
                    for: characteristic,
                    type: .withoutResponse
                )
            }

            if chunks.isEmpty {
                status = "Текст отправлен"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            status = "Ошибка передачи: \(error.localizedDescription)"
            chunks.removeAll()
            return
        }

        if !chunks.isEmpty {
            chunks.removeFirst()
        }

        sendNextChunk()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sendNextChunk()
    }
}

// MARK: - Speech recognition

final class SpeechManager: ObservableObject {

    @Published var text = ""
    @Published var status = "Нажми «Начать прослушивание»"
    @Published var isListening = false

    var onAnswer: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(
        locale: Locale(identifier: "ru-RU")
    )

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: DispatchWorkItem?

    private var lastText = ""
    private var answerSent = false

    func start() {
        guard !isListening else { return }

        status = "Запрашиваю разрешения..."

        SFSpeechRecognizer.requestAuthorization { [weak self] speechAuth in
            AVAudioSession.sharedInstance().requestRecordPermission {
                [weak self] microphoneGranted in

                DispatchQueue.main.async {
                    guard let self else { return }

                    guard speechAuth == .authorized &&
                          microphoneGranted else {
                        self.status = "Разреши микрофон и распознавание речи в настройках"
                        return
                    }

                    self.beginListening()
                }
            }
        }
    }

    private func beginListening() {
        guard let recognizer, recognizer.isAvailable else {
            status = "Распознавание речи сейчас недоступно"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )

            try session.setActive(true)

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            request = newRequest
            lastText = ""
            text = ""
            answerSent = false

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            input.removeTap(onBus: 0)

            input.installTap(
                onBus: 0,
                bufferSize: 2048,
                format: format
            ) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            engine.prepare()
            try engine.start()

            isListening = true
            status = "Слушаю голосовой ответ..."

            task = recognizer.recognitionTask(with: newRequest) {
                [weak self] result, error in

                guard let self else { return }

                if let result {
                    let recognized = result.bestTranscription.formattedString

                    DispatchQueue.main.async {
                        self.lastText = recognized
                        self.text = recognized
                        self.scheduleFinish()
                    }
                }

                if let error {
                    DispatchQueue.main.async {
                        if !self.answerSent {
                            self.status = "Распознавание остановлено: \(error.localizedDescription)"
                        }
                    }
                }
            }

        } catch {
            status = "Ошибка аудио: \(error.localizedDescription)"
            stop()
        }
    }

    private func scheduleFinish() {
        silenceTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.lastText.isEmpty,
                  !self.answerSent else { return }

            self.answerSent = true
            let answer = self.lastText

            self.status = "Ответ распознан и отправляется"
            self.onAnswer?(answer)
            self.stop()
        }

        silenceTimer = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.5,
            execute: work
        )
    }

    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil

        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }

        request?.endAudio()
        task?.cancel()

        request = nil
        task = nil

        isListening = false
    }
}

// MARK: - Application screen

struct ContentView: View {

    @StateObject private var speech = SpeechManager()
    @StateObject private var bluetooth = BluetoothManager()

    var body: some View {
        NavigationView {
            VStack(spacing: 15) {

                Text("SMART PEN")
                    .font(.largeTitle.bold())

                Text(speech.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    if speech.isListening {
                        speech.stop()
                    } else {
                        speech.start()
                    }
                } label: {
                    Text(
                        speech.isListening
                        ? "Остановить прослушивание"
                        : "Начать прослушивание"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("Текст ответа")
                    .font(.headline)

                ScrollView {
                    Text(
                        speech.text.isEmpty
                        ? "Здесь появится распознанный ответ"
                        : speech.text
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(height: 170)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(12)
                Divider()

                Text("Bluetooth")
                    .font(.headline)

                Text(bluetooth.status)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button("Найти BLE устройства") {
                    bluetooth.scan()
                }
                .buttonStyle(.bordered)

                List(bluetooth.devices, id: \.identifier) { device in
                    Button(device.name ?? "BLE устройство") {
                        bluetooth.connect(device)
                    }
                }
                .frame(height: 130)

                Text("Подключено: \(bluetooth.connectedName)")
                    .font(.footnote)

                Button("Отправить ответ на плату") {
                    bluetooth.send(speech.text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(speech.text.isEmpty)
            }
            .padding()
            .navigationBarHidden(true)
            .onAppear {
                speech.onAnswer = { answer in
                    bluetooth.send(answer)
                }
            }
        }
    }
}
