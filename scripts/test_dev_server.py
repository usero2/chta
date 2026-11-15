import tempfile
import unittest
from pathlib import Path

from scripts.dev_server import RoomStore, should_serve_app_shell


class RoomStoreTest(unittest.TestCase):
    def test_offer_and_answer_round_trip(self) -> None:
        rooms = RoomStore()
        code = rooms.create("offer-json")

        self.assertRegex(code, r"^\d{6}$")
        self.assertEqual(rooms.offer(code), "offer-json")
        self.assertIsNone(rooms.answer(code))
        self.assertTrue(rooms.set_answer(code, "answer-json"))
        self.assertEqual(rooms.answer(code), "answer-json")

    def test_unknown_room_rejects_answer(self) -> None:
        self.assertFalse(RoomStore().set_answer("000000", "answer-json"))

    def test_client_routes_are_served_by_the_app_shell(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            (directory / "main.dart.js").write_text("", encoding="utf-8")

            self.assertTrue(should_serve_app_shell("/contacts", directory))
            self.assertTrue(
                should_serve_app_shell("/connect/did%3Acht%3Afriend", directory)
            )
            self.assertFalse(should_serve_app_shell("/main.dart.js", directory))
            self.assertFalse(should_serve_app_shell("/api/rooms", directory))


if __name__ == "__main__":
    unittest.main()
