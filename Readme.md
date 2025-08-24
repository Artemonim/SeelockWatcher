# Seelock Watcher
[English below](#purpose)

## Назначение
Утилита для автоматического резервного копирования и конвертации видео с видеорегистратора Seelock Inspector B2. Возможно, совместима с другими моделями Seelock.

## Возможности
- Автоматическое подключение к устройству и монтирование его как диска.
- Поиск всех видеофайлов на устройстве.
- Конвертация видео в формат 720p MP4 (H.264/H.265) для экономии места.
- Автоматическое определение наилучшего доступного аппаратного кодировщика (NVIDIA NVENC, AMD AMF, Intel QSV) для максимальной скорости.
- Копирование не-видео файлов для полного сохранения структуры папок с устройства.
- Удаление исходных файлов после конвертации (настраивается).

## Требования
1.  **Windows 10/11** с **PowerShell 5.1** или новее.
2.  [**Seelock Connect LTE**](https://seelock.ru/instrukczii.html): Программное обеспечение от производителя, установленное в системе.
3.  **FFmpeg**: Утилита для обработки видео. `ffmpeg.exe` и `ffprobe.exe` должны быть доступны в системной переменной `PATH`.

## Установка и настройка
1.  **Установите Seelock Connect LTE**. Если вы установили его в нестандартное место, вам нужно будет указать путь в файле `Config.ini`.
2.  **Установите FFmpeg**. Скачайте его с официального сайта и добавьте путь к `bin` папке (где находятся `ffmpeg.exe` и `ffprobe.exe`) в системную переменную `PATH`.
3.  **Настройте `Config.ini`**:
    - `ExePath`: Путь к `SeelockConnectLTE.exe`. По умолчанию: `C:\Program Files\Seelock Connect LTE\SeelockConnectLTE.exe`.
    - `Password`: Пароль для доступа к устройству. По умолчанию: `000000`.
    - `OutputPath`: Папка для сохранения сконвертированных видео. По умолчанию: `./Videos`.
    - `DeleteAfterConvert`: `true` для удаления оригиналов после конвертации, `false` чтобы их оставить. По умолчанию: `true`.

## Использование
Для простого запуска, используйте `Create-Shortcut.bat`, чтобы создать ярлык на рабочем столе.

1.  (Опционально) Поместите файл иконки `seelock.ico` в корневую папку проекта. Если файл не будет найден, будет использована стандартная иконка PowerShell.
2.  Запустите `Create-Shortcut.bat` двойным щелчком мыши.
3.  На вашем рабочем столе появится ярлык "Seelock Watcher Sync".
4.  Используйте этот ярлык для запуска процесса синхронизации. Процесс полностью автоматический.


---

# Seelock Watcher

## Purpose
A utility for automatically backing up and converting videos from the Seelock Inspector B2 DVR. It may also be compatible with other Seelock models.

This application is designed for convenient video backup. The intended workflow for the end-user is to run the process via a desktop shortcut.

## Features
- Automatically connects to the device and mounts it as a drive.
- Finds all video files on the device.
- Converts videos to 720p MP4 (H.264/H.265) to save space.
- Automatically detects the best available hardware encoder (NVIDIA NVENC, AMD AMF, Intel QSV) for maximum speed.
- Copies non-video files to fully preserve the folder structure from the device.
- Deletes original files after conversion (configurable).

## Requirements
1.  **Windows 10/11** with **PowerShell 5.1** or newer.
2.  [**Seelock Connect LTE**](https://seelock.ru/instrukczii.html): The manufacturer's software must be installed.
3.  **FFmpeg**: The video processing utility. `ffmpeg.exe` and `ffprobe.exe` must be available in the system's `PATH`.

## Installation and Configuration
1.  **Install Seelock Connect LTE**. If you installed it in a non-default location, you will need to specify the path in the `Config.ini` file.
2.  **Install FFmpeg**. Download it from the official website and add the path to the `bin` folder (containing `ffmpeg.exe` and `ffprobe.exe`) to your system's `PATH` environment variable.
3.  **Configure `Config.ini`**:
    - `ExePath`: Path to `SeelockConnectLTE.exe`. Default: `C:\Program Files\Seelock Connect LTE\SeelockConnectLTE.exe`.
    - `Password`: Password to access the device. Default: `000000`.
    - `OutputPath`: Folder to save converted videos. Default: `./Videos`.
    - `DeleteAfterConvert`: `true` to delete original files after conversion, `false` to keep them. Default: `true`.

## Usage
For easy access, use the `Create-Shortcut.bat` script to create a desktop shortcut.

1.  (Optional) Place an icon file named `seelock.ico` in the project's root folder. If not found, the default PowerShell icon will be used.
2.  Run `Create-Shortcut.bat` by double-clicking it.
3.  A shortcut named "Seelock Watcher Sync" will be created on your desktop.
4.  Use this shortcut to start the synchronization process. The process is fully automatic.
