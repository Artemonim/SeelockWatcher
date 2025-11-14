# This script defines localized strings for the Seelock Watcher scripts.
# It detects the system's UI language and exports a hashtable of strings.

# Determine the UI language
$lang = (Get-UICulture).TwoLetterISOLanguageName

if ($lang -eq 'ru') {
    # Russian strings
    $Strings = @{
        # sync.ps1
        Sync_Connecting          = "Попытка подключения к устройству Seelock..."
        Sync_ConnectionFailed    = "Не удалось подключиться к устройству. Проверьте пароль и убедитесь, что устройство подключено.`nСведения об ошибке: {0}"
        Sync_CannotGetDrive      = "Не удалось определить букву диска из вывода скрипта подключения.`nВывод: {0}"
        Sync_MountSuccess        = "[УСПЕХ] Устройство смонтировано как диск {0}"
        Sync_ConversionStarting  = "Запуск конвертации видео из '{0}\DCIM' в '{1}'..."
        Sync_ConversionFailed    = "Скрипт конвертации видео завершился с ошибками."
        Sync_CompleteSuccess     = "[ЗАВЕРШЕНО] Процесс синхронизации успешно завершен."
        Sync_OverallFailure      = "Синхронизация не удалась: {0}"

        # Convert-SeelockVideos.ps1
        Convert_FFmpegNotFound   = @"
FFmpeg не установлен или не доступен в системной переменной PATH.
Пожалуйста, загрузите его с https://ffmpeg.org/ и убедитесь, что ffmpeg.exe находится в PATH.
"@
        Convert_SourceNotFound   = "Исходная папка не найдена: {0}. Нечего конвертировать."
        Convert_NoVideos         = "Видеофайлы в {0} не найдены."
        Convert_VideosFound      = "Найдено видеофайлов для обработки: {0}."
        Convert_ConvertingFile   = "Конвертация {0}..."
        Convert_ConvertSuccess   = "[УСПЕХ] Сконвертировано в {0}"
        Convert_ConvertFailed    = "[СБОЙ] FFmpeg не удалось конвертировать {0}."
        Convert_ProcessComplete  = "Процесс конвертации видео завершен."
        Convert_UsingEncoder     = "Используется видеокодер: {0}"
        Convert_CalcWorkload     = "Расчет общего объема для ETA..."
        Convert_TotalDuration    = "Суммарная длительность видео: {0}"
        Convert_CopyingOther     = "Копирование {0} не-видео файла(ов)..."
        Summary_Header           = "--- Итоги операции ---"
        Summary_Total            = "  - Всего видео к обработке: {0}"
        Summary_Success          = "  - Успешно сконвертировано: {0}"
        Summary_Failed           = "  - Сбоев при конвертации: {0}"
        Summary_Copied           = "  - Скопировано прочих файлов: {0}"
        Summary_CopyErrors       = "  - Ошибок копирования: {0}"
        Summary_Elapsed          = "  - Затраченное время: {0}"
        Summary_SizeDelta        = "  - Изменение общего размера: {0}{1:N2} MB ({2}{3:N2}%)"
        Summary_OutputFolder     = "  - Папка результата: {0}"
        Convert_RetentionScanning = "Проверка '{0}' на файлы старше {1} дней..."
        Convert_RetentionNone     = "Файлов старше {0} дней не найдено."
        Convert_RetentionFound    = "Найдено {0} файла(-ов), старше {1} дней."
        Convert_RetentionPrompt   = "Удалить эти файлы старше {0} дней? (Y/N)"
        Convert_RetentionDeleting = "Удаляю устаревшие файлы..."
        Convert_RetentionDeleted  = "Удалено {0} файла(-ов)."
        Convert_RetentionSkipped  = "Удаление отменено пользователем."
        Convert_RetentionCleaning = "Удаляю пустые папки..."
        Convert_RetentionDirClean = "Удалена пустая папка: {0}"
    }
} else {
    # English strings (default)
    $Strings = @{
        # sync.ps1
        Sync_Connecting          = "Attempting to connect to Seelock device..."
        Sync_ConnectionFailed    = "Failed to connect to the device. Please check the password and ensure the device is connected.`nError details: {0}"
        Sync_CannotGetDrive      = "Could not determine the drive letter from the connection script output.`nRaw output: {0}"
        Sync_MountSuccess        = "[SUCCESS] Device mounted as drive {0}"
        Sync_ConversionStarting  = "Starting video conversion from '{0}\DCIM' to '{1}'..."
        Sync_ConversionFailed    = "Video conversion script finished with errors."
        Sync_CompleteSuccess     = "[COMPLETE] Synchronization process finished successfully."
        Sync_OverallFailure      = "Synchronization failed: {0}"

        # Convert-SeelockVideos.ps1
        Convert_FFmpegNotFound   = @"
FFmpeg is not installed or not available in your system's PATH.
Please download it from https://ffmpeg.org/ and ensure ffmpeg.exe is in your PATH.
"@
        Convert_SourceNotFound   = "Source folder not found: {0}. Nothing to convert."
        Convert_NoVideos         = "No video files found in {0}."
        Convert_VideosFound      = "Found {0} video(s) to process."
        Convert_ConvertingFile   = "Converting {0}..."
        Convert_ConvertSuccess   = "[SUCCESS] Converted to {0}"
        Convert_ConvertFailed    = "[FAILED] FFmpeg failed to convert {0}."
        Convert_ProcessComplete  = "Video conversion process completed."
        Convert_UsingEncoder     = "Using video encoder: {0}"
        Convert_CalcWorkload     = "Calculating total workload for ETA..."
        Convert_TotalDuration    = "Total video duration: {0}"
        Convert_CopyingOther     = "Copying {0} non-video file(s)..."
        Summary_Header           = "--- Operation Summary ---"
        Summary_Total            = "  - Total videos considered: {0}"
        Summary_Success          = "  - Successful conversions: {0}"
        Summary_Failed           = "  - Failed conversions:       {0}"
        Summary_Copied           = "  - Other files copied:     {0}"
        Summary_CopyErrors       = "  - File copy errors:       {0}"
        Summary_Elapsed          = "  - Elapsed time: {0}"
        Summary_SizeDelta        = "  - Total size delta: {0}{1:N2} MB ({2}{3:N2}%)"
        Summary_OutputFolder     = "  - Output folder: {0}"
        Convert_RetentionScanning = "Scanning '{0}' for files older than {1} day(s)..."
        Convert_RetentionNone     = "No files older than {0} day(s) were found."
        Convert_RetentionFound    = "Found {0} file(s) older than {1} day(s)."
        Convert_RetentionPrompt   = "Delete files older than {0} day(s)? (Y/N)"
        Convert_RetentionDeleting = "Deleting stale files..."
        Convert_RetentionDeleted  = "Deleted {0} file(s)."
        Convert_RetentionSkipped  = "Old files are left in place."
        Convert_RetentionCleaning = "Removing empty directories..."
        Convert_RetentionDirClean = "Removed empty directory: {0}"
    }
}

# Export the variable only when imported as a module (safe for dot-sourcing)
if ($ExecutionContext -and $ExecutionContext.SessionState -and $ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Variable Strings
}
