import os
import unittest
from unittest.mock import patch

from pw_bot_runtime.display import MirroredXvfbDisplay, make_display


class VisibleDisplayIsolationTests(unittest.TestCase):
    @patch.dict(os.environ, {"PW_BOT_VISIBLE_BACKEND": "mirror"}, clear=False)
    def test_environment_can_force_the_read_only_visible_backend(self):
        display = make_display(
            mode="visible",
            backend="xephyr",
            width=1280,
            height=720,
            allow_host=False,
        )

        self.assertIsInstance(display, MirroredXvfbDisplay)


if __name__ == "__main__":
    unittest.main()
