import QtQuick

QtObject {
    // All stable helper codes have a product message. Never display raw replies.
    function errorText(code) {
        switch (code) {
        case "invalid_username": return qsTr("帳號名稱須以英文小寫字母開頭，只能用小寫字母、數字與「-」，最多 31 個字元，並避開系統保留名稱。");
        case "username_taken": return qsTr("這個帳號名稱已被使用，請換一個名稱。");
        case "password_too_short": return qsTr("密碼至少需要 8 個字元，請重新輸入。");
        case "password_invalid": return qsTr("密碼不能含換行或空字元，最多 511 個 UTF-8 位元組，請重新輸入。");
        case "display_name_invalid": return qsTr("名字最多 128 個字元，不能含控制字元或「: , =」，請修改後再試。");
        case "already_provisioned": return qsTr("這台電腦已經有帳號，請回到登入畫面登入。");
        case "unauthorized": return qsTr("目前的畫面無權建立帳號，請重新啟動電腦後再試。");
        case "internal_rolled_back": return qsTr("帳號沒有建立成功，系統已回復，可以重新填寫再試一次。");
        case "internal_rollback_failed": return qsTr("帳號建立失敗，系統無法完整回復。請重新啟動電腦進行復原，暫時不要再次建立帳號。");
        case "unavailable": return qsTr("登入服務目前無法使用，尚未送出建立帳號的請求。請重新啟動電腦後再試。");
        case "pam_failed": return qsTr("帳號已建立，但登入驗證失敗。請回到登入畫面，用剛設定的帳號與密碼登入。");
        default: return qsTr("目前無法確認帳號是否已建立。請重新啟動電腦，讓系統檢查狀態；不要重複送出。");
        }
    }
}
