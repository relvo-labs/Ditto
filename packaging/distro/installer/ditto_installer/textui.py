"""English console frontend for machines without a usable display (no DRM).

The Linux console cannot show Chinese, so this path is English only (same
reasoning as the #212 text fallback). Enter alone always means cancel; the
destructive step needs the word ERASE typed explicitly.
"""

import select
import sys
import time

from . import messages
from .client import Client, ConnectionLost

EN = "en"


def msg(table, code):
    return messages.text(table, code, EN) if code in table else code


class Terminal:
    def __init__(self, stdin=sys.stdin, stdout=sys.stdout):
        self.stdin, self.stdout = stdin, stdout

    def write(self, text):
        self.stdout.write(text)
        self.stdout.flush()

    def read_line(self, prompt):
        self.write(prompt)
        line = self.stdin.readline()
        return None if line == "" else line.rstrip("\n")

    def poll_line(self, timeout):
        ready, _, _ = select.select([self.stdin], [], [], timeout)
        if not ready:
            return None
        line = self.stdin.readline()
        return None if line == "" else line.rstrip("\n")


class TextUI:
    def __init__(self, client, terminal, *, interval=0.5, sleep=time.sleep):
        self.client, self.term = client, terminal
        self.interval, self.sleep = interval, sleep

    def say(self, text=""):
        self.term.write(text + "\n")

    def run(self):
        try:
            return self._run()
        except ConnectionLost:
            self.say()
            self.say(msg(messages.RESULTS, "service_lost"))
            self.term.read_line("Press Enter to continue.")
            return 1

    def _run(self):
        self.say("Ditto installer (text mode)")
        while True:
            state = self.client.request("state")
            if state["medium"] == "searching":
                self.say(msg(messages.STATUS, "searching"))
                self.sleep(1.0)
                continue
            if state["medium"] != "ready":
                self.say(msg(messages.RESULTS, state["medium"]))
                return self._offer_reboot("Press Enter to restart the computer.")
            phase = state["state"]
            if phase == "installing":
                self._watch()
            elif phase == "succeeded":
                self.say(msg(messages.RESULTS, "ok"))
                return self._offer_reboot(msg(messages.STATUS, "remove_media") + " Press Enter to restart.")
            elif phase in ("failed", "cancelled"):
                self._show_result(state["result"])
                answer = self.term.read_line("Press Enter to choose a disk again, or type 'reboot' to restart: ")
                if answer is None or answer.strip().lower() == "reboot":
                    return self._offer_reboot(None)
                self.client.request("list")      # returns the session to the list
            else:
                done = self._choose(state.get("notice"))
                if done is not None:
                    return done

    def _offer_reboot(self, prompt):
        if prompt:
            self.term.read_line(prompt)
        reply = self.client.request("reboot")
        if not reply.get("ok"):
            self.say("Restart is not possible right now.")
            return 1
        self.say("Restarting...")
        return 0

    def _show_result(self, result):
        if not result:
            self.say(msg(messages.RESULTS, "internal_error"))
            return
        self.say(msg(messages.RESULTS, result["code"]))
        extra = msg(messages.DISK_STATE, result["disk_state"])
        if extra:
            self.say(extra)

    def _choose(self, notice):
        reply = self.client.request("list")
        if not reply.get("ok"):
            self.say(msg(messages.RESULTS, "stale_action"))
            return None
        self.say()
        if notice:
            self.say(msg(messages.RESULTS, notice))
        self.say("Choose the disk to install Ditto on:")
        selectable = []
        for disk in reply["disks"]:
            line = (f"{disk['name']}  {disk['model'] or '(unknown model)'}  {messages.size_text(disk['size_bytes'])}"
                    f"  serial {disk['serial'] or '(unknown)'}")
            if disk["token"]:
                selectable.append(disk)
                self.say(f"  {len(selectable)}) {line}")
            else:
                reasons = "; ".join(msg(messages.EXCLUDED, r) for r in disk["reasons"])
                self.say(f"  -  {line}  [not available: {reasons}]")
        if not selectable:
            self.say(msg(messages.STATUS, "no_disk"))
        answer = self.term.read_line("Enter a number, 'r' to refresh, or 'reboot': ")
        if answer is None:
            return 1
        answer = answer.strip().lower()
        if answer == "reboot":
            return self._offer_reboot(None)
        if not answer.isdigit() or not 1 <= int(answer) <= len(selectable):
            return None
        chosen = self.client.request("select", token=selectable[int(answer) - 1]["token"])
        if not chosen.get("ok"):
            self.say(msg(messages.RESULTS, "stale_action"))
            return None
        disk = chosen["disk"]
        self.say()
        self.say("Install Ditto on this disk?")
        self.say(f"  Model:  {disk['model'] or '(unknown)'}")
        self.say(f"  Size:   {messages.size_text(disk['size_bytes'])} ({disk['size_bytes']} bytes)")
        self.say(f"  Serial: {disk['serial'] or '(unknown)'}")
        self.say(f"  {msg(messages.STATUS, 'erase_warning')}.")
        answer = self.term.read_line("Type ERASE and press Enter to install. Press Enter alone to cancel: ")
        if answer is None or answer.strip() != "ERASE":
            self.client.request("back")
            self.say("Cancelled. Nothing was written.")
            return None
        started = self.client.request("confirm", token=chosen["confirm_token"])
        if not started.get("ok"):
            code = started.get("error")
            self.say(msg(messages.RESULTS, code if code in messages.RESULTS else "stale_action"))
        return None

    def _watch(self):
        self.say("Installing. Type 'c' and press Enter to cancel.")
        cancelling = False
        while True:
            state = self.client.request("state")
            if state["state"] != "installing":
                self.say()
                return
            progress = state["progress"]
            stage = msg(messages.STAGES, progress["stage"]) if progress["stage"] else ""
            percent = f" {100 * progress['done'] // progress['total']}%" if progress["total"] else ""
            self.term.write(f"\r{stage}{percent}        ")
            line = self.term.poll_line(self.interval)
            if line is not None and line.strip().lower() == "c" and not cancelling:
                if self.client.request("cancel").get("ok"):
                    cancelling = True
                    self.say()
                    self.say(msg(messages.STATUS, "cancelling"))


def main():
    sys.exit(TextUI(Client(), Terminal()).run())
