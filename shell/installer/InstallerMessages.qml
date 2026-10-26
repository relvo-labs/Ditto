import QtQuick

// Product text for backend codes. Kept identical to packaging/distro/installer/
// ditto_installer/messages.py (zh-TW column); a test compares the two.
QtObject {
    function result(code) {
        switch (code) {
        case "ok": return qsTr("安裝完成，內容已逐一讀回核對。請拔除安裝媒體，再重新開機。");
        case "cancelled": return qsTr("已取消安裝。");
        case "manifest_mismatch": return qsTr("安裝媒體上的內容與安裝程式不符，沒有寫入任何磁碟。請重新下載 ISO、核對 SHA256 後再製作安裝媒體。");
        case "manifest_invalid": return qsTr("安裝媒體上的清單無法辨識，沒有寫入任何磁碟。請重新製作安裝媒體。");
        case "payload_missing": return qsTr("安裝媒體缺少必要檔案，沒有寫入任何磁碟。請重新製作安裝媒體。");
        case "payload_unsafe": return qsTr("安裝媒體上的檔案型態不正確，沒有寫入任何磁碟。請重新製作安裝媒體。");
        case "payload_size_mismatch": return qsTr("安裝媒體上的檔案已損毀，沒有寫入任何磁碟。請重新下載並核對 SHA256。");
        case "payload_hash_mismatch": return qsTr("安裝媒體上的資料核對不符，安裝已停止。請重新下載並核對 SHA256。");
        case "payload_length_mismatch": return qsTr("安裝媒體上的資料長度不符，安裝已停止。請重新下載並核對 SHA256。");
        case "decompress_failed": return qsTr("解開安裝資料時失敗，安裝已停止。請重新製作安裝媒體。");
        case "target_too_small": return qsTr("這顆磁碟容量不足，沒有寫入任何資料。請選擇更大的磁碟。");
        case "target_unusable": return qsTr("無法以獨占方式開啟這顆磁碟（可能正被使用），沒有寫入任何資料。");
        case "target_changed": return qsTr("磁碟狀態和確認時不同，沒有寫入任何資料。請重新選擇磁碟。");
        case "disk_changed": return qsTr("磁碟狀態和確認時不同，沒有寫入任何資料。請重新選擇磁碟。");
        case "write_error": return qsTr("寫入磁碟時發生錯誤，安裝已停止。");
        case "read_error": return qsTr("讀回核對時發生錯誤，安裝已停止。");
        case "readback_mismatch": return qsTr("寫入後讀回的內容不符，安裝已停止。這顆磁碟可能有問題。");
        case "commit_failed": return qsTr("寫入分割表時失敗，安裝已停止。");
        case "internal_error": return qsTr("目前無法確認安裝結果。請不要使用這顆磁碟開機，重新執行安裝。");
        case "medium_unavailable": return qsTr("找不到安裝媒體，或媒體上的安裝資料不完整，沒有寫入任何磁碟。請確認隨身碟已插好；問題持續時請重新製作安裝媒體。");
        case "service_lost": return qsTr("安裝服務已停止，目前無法確認結果。請不要從目標磁碟開機；重新開機後再安裝一次。");
        case "stale_action": return qsTr("這個畫面已過期，已重新整理磁碟清單。");
        default: return qsTr("目前無法確認安裝結果。請不要使用這顆磁碟開機，重新執行安裝。");
        }
    }
    function excluded(code) {
        switch (code) {
        case "install_medium": return qsTr("這是安裝用的隨身碟或光碟，不能安裝到這裡。");
        case "in_use": return qsTr("這顆磁碟正在使用中（已掛載或被其他系統占用）。");
        case "read_only": return qsTr("這顆磁碟是唯讀的，無法寫入。");
        case "removable": return qsTr("可移除式裝置不列為安裝目標。");
        case "unsupported_sector_size": return qsTr("這顆磁碟使用 4K 原生磁區，預覽版尚未支援。");
        case "too_small": return qsTr("容量不足，無法安裝 Ditto。");
        case "unreadable": return qsTr("讀不到這顆磁碟的資訊，不提供安裝。");
        default: return qsTr("讀不到這顆磁碟的資訊，不提供安裝。");
        }
    }
    function stage(code) {
        switch (code) {
        case "verify": return qsTr("正在核對安裝資料");
        case "preflight": return qsTr("正在準備磁碟");
        case "wipe": return qsTr("正在清除舊的分割表");
        case "write": return qsTr("正在寫入");
        case "readback": return qsTr("正在讀回核對");
        case "commit": return qsTr("正在寫入分割表");
        case "done": return qsTr("完成");
        default: return "";
        }
    }
    function diskState(code) {
        switch (code) {
        case "untouched": return qsTr("這顆磁碟的資料沒有被更動。");
        case "partially_written": return qsTr("這顆磁碟的原有資料已被部分清除，目前無法開機。可以重新安裝，或改用其他磁碟。");
        default: return "";
        }
    }
    function status(code) {
        switch (code) {
        case "searching": return qsTr("正在尋找安裝媒體…");
        case "no_disk": return qsTr("沒有可以安裝的磁碟。");
        case "erase_warning": return qsTr("將清除整顆磁碟的全部資料");
        case "remove_media": return qsTr("請拔除安裝媒體，再重新開機。");
        case "cancelling": return qsTr("正在取消…");
        case "cancel_too_late": return qsTr("已經在寫入分割表，來不及取消。請等待安裝結果。");
        default: return "";
        }
    }
}
