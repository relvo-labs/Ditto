"""User-facing text for reason and result codes (zh-TW graphical, English console).

Product layer only: what happened, what state the disk is in, what to do next.
Codes and raw details belong in the diagnostic area, not in these sentences.
"""

EXCLUDED = {
    "install_medium": ("這是安裝用的隨身碟或光碟，不能安裝到這裡。",
                       "This is the installation medium."),
    "in_use": ("這顆磁碟正在使用中（已掛載或被其他系統占用）。",
               "This disk is in use (mounted or held by another device)."),
    "read_only": ("這顆磁碟是唯讀的，無法寫入。", "This disk is read-only."),
    "removable": ("可移除式裝置不列為安裝目標。", "Removable devices are not offered as targets."),
    "unsupported_sector_size": ("這顆磁碟使用 4K 原生磁區，預覽版尚未支援。",
                                "Disks with 4K native sectors are not supported in this preview."),
    "too_small": ("容量不足，無法安裝 Ditto。", "This disk is too small for Ditto."),
    "unreadable": ("讀不到這顆磁碟的資訊，不提供安裝。", "This disk's details could not be read."),
}

RESULTS = {
    "ok": ("安裝完成，內容已逐一讀回核對。請拔除安裝媒體，再重新開機。",
           "Installation finished and was verified by reading it back. Remove the installation medium and restart."),
    "cancelled": ("已取消安裝。", "Installation cancelled."),
    "manifest_mismatch": ("安裝媒體上的內容與安裝程式不符，沒有寫入任何磁碟。請重新下載 ISO、核對 SHA256 後再製作安裝媒體。",
                          "The medium's contents do not match this installer. Nothing was written. Download the ISO again and check its SHA256."),
    "manifest_invalid": ("安裝媒體上的清單無法辨識，沒有寫入任何磁碟。請重新製作安裝媒體。",
                         "The medium's payload list is invalid. Nothing was written. Recreate the installation medium."),
    "payload_missing": ("安裝媒體缺少必要檔案，沒有寫入任何磁碟。請重新製作安裝媒體。",
                        "A required file is missing from the medium. Nothing was written."),
    "payload_unsafe": ("安裝媒體上的檔案型態不正確，沒有寫入任何磁碟。請重新製作安裝媒體。",
                       "A file on the medium has an unexpected type. Nothing was written."),
    "payload_size_mismatch": ("安裝媒體上的檔案已損毀，沒有寫入任何磁碟。請重新下載並核對 SHA256。",
                              "A file on the medium is damaged. Nothing was written. Download again and check the SHA256."),
    "payload_hash_mismatch": ("安裝媒體上的資料核對不符，安裝已停止。請重新下載並核對 SHA256。",
                              "Data on the medium failed verification and installation stopped. Download again and check the SHA256."),
    "payload_length_mismatch": ("安裝媒體上的資料長度不符，安裝已停止。請重新下載並核對 SHA256。",
                                "Data on the medium has the wrong length and installation stopped."),
    "decompress_failed": ("解開安裝資料時失敗，安裝已停止。請重新製作安裝媒體。",
                          "Unpacking the installation data failed and installation stopped."),
    "target_too_small": ("這顆磁碟容量不足，沒有寫入任何資料。請選擇更大的磁碟。",
                         "The disk is too small. Nothing was written. Choose a larger disk."),
    "target_unusable": ("無法以獨占方式開啟這顆磁碟（可能正被使用），沒有寫入任何資料。",
                        "The disk could not be opened exclusively (it may be in use). Nothing was written."),
    "target_changed": ("磁碟狀態和確認時不同，沒有寫入任何資料。請重新選擇磁碟。",
                       "The disk changed since you confirmed it. Nothing was written. Choose the disk again."),
    "disk_changed": ("磁碟狀態和確認時不同，沒有寫入任何資料。請重新選擇磁碟。",
                     "The disk changed since you confirmed it. Nothing was written. Choose the disk again."),
    "write_error": ("寫入磁碟時發生錯誤，安裝已停止。", "Writing to the disk failed and installation stopped."),
    "read_error": ("讀回核對時發生錯誤，安裝已停止。", "Reading the disk back failed and installation stopped."),
    "readback_mismatch": ("寫入後讀回的內容不符，安裝已停止。這顆磁碟可能有問題。",
                          "The data read back did not match and installation stopped. The disk may be faulty."),
    "commit_failed": ("寫入分割表時失敗，安裝已停止。", "Writing the partition table failed and installation stopped."),
    "internal_error": ("目前無法確認安裝結果。請不要使用這顆磁碟開機，重新執行安裝。",
                       "The result could not be determined. Do not boot from this disk; run the installation again."),
}

DISK_STATE = {
    "untouched": ("這顆磁碟的資料沒有被更動。", "The disk was not changed."),
    "partially_written": ("這顆磁碟的原有資料已被部分清除，目前無法開機。可以重新安裝，或改用其他磁碟。",
                          "The disk's previous data was partly erased and it will not boot. Install again or use another disk."),
    "installed": ("", ""),
    "unknown": ("", ""),
}


def text(table, code, language="zh-TW"):
    entry = table[code]
    return entry[0] if language == "zh-TW" else entry[1]
