"""Synthesize a varied, three-minute English/Ukrainian meeting conversation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import wave


SAMPLE_RATE = 16000
TARGET_SECONDS = 180
TURN_GAP_SECONDS = 0.35

# A two-person project review. Each turn responds to the previous one; no line
# is looped. Samantha speaks English and Lesya speaks Ukrainian using local
# macOS voices so the exact reference transcript is known.
DIALOGUE = (
    ('Samantha', 'The launch review is on Friday, and we still need to settle the schedule.'),
    ('Lesya', 'Так, я переглянула план. Зараз найбільше ризикуємо через затримку перекладу.'),
    ('Samantha', 'I thought the vendor promised the Ukrainian draft by Wednesday morning.'),
    ('Lesya', 'Вони обіцяли, але редактор захворів. Нову дату підтвердять сьогодні після обіду.'),
    ('Samantha', 'Could we ask someone on our team to review the first few pages?'),
    ('Lesya', 'Можемо. Андрій добре знає продукт і вже допомагав із попередньою презентацією.'),
    ('Samantha', 'Great. Please ask him to focus on the setup steps and button labels.'),
    ('Lesya', 'Домовились. Я надішлю йому посилання та поясню, де залишати коментарі.'),
    ('Samantha', 'We also need to decide whether Friday means a full release or a preview.'),
    ('Lesya', 'Я пропоную спочатку зробити обмежений запуск для десяти команд.'),
    ('Samantha', 'That gives us useful feedback without putting every customer at risk.'),
    ('Lesya', 'Саме так. За перший день ми перевіримо помилки, швидкість і зрозумілість інструкцій.'),
    ('Samantha', 'Do we have enough support coverage if several teams start at once?'),
    ('Lesya', 'У п’ятницю чергуватимуть двоє людей, а я буду доступна в робочому чаті.'),
    ('Samantha', 'Let us confirm the support schedule before we send the invitations.'),
    ('Lesya', 'Добре. Ще потрібно підготувати коротку форму для відгуків користувачів.'),
    ('Samantha', 'What should the form ask besides whether the setup was successful?'),
    ('Lesya', 'Запитаємо, де люди зупинилися, що було незрозумілим і скільки часу це зайняло.'),
    ('Samantha', 'Please keep it short, maybe three questions and an optional comment box.'),
    ('Lesya', 'Зроблю. Так більше людей завершать форму, а відповіді буде легше порівняти.'),
    ('Samantha', 'For the presentation, we need one slide showing the old and new workflow.'),
    ('Lesya', 'Я можу підготувати схему сьогодні. Чи залишаємо старий екран у додатку?'),
    ('Samantha', 'Yes, keep it available for now, but explain when customers should use it.'),
    ('Lesya', 'Тоді додам примітку, що новий процес ще проходить перевірку на малих командах.'),
    ('Samantha', 'How many invitations can we send before the launch review on Friday?'),
    ('Lesya', 'Почнімо з десяти. Якщо всі погодяться, наступного тижня запросимо ще двадцять.'),
    ('Samantha', 'That sounds manageable. We should include both new and experienced users.'),
    ('Lesya', 'Так, інакше ми почуємо лише тих, хто вже знає продукт.'),
    ('Samantha', 'I will ask support to nominate three people who recently joined.'),
    ('Lesya', 'А я знайду кількох постійних користувачів, які можуть швидко перевірити оновлення.'),
    ('Samantha', 'Before we wrap up, who owns the final decision to expand the release?'),
    ('Lesya', 'Ми з тобою перевіримо відгуки в понеділок і разом вирішимо, що робити далі.'),
    ('Samantha', 'Please add a clear checklist so we do not rely on memory.'),
    ('Lesya', 'Додам власника, термін і посилання на кожне завдання в спільний документ.'),
    ('Samantha', 'I can review the checklist tomorrow morning and flag anything missing.'),
    ('Lesya', 'Чудово. Я також перевірю український текст після того, як Андрій надішле правки.'),
    ('Samantha', 'Then we will share the preview plan with the wider team on Thursday.'),
    ('Lesya', 'Так, а запрошення клієнтам надішлемо лише після нашої п’ятничної зустрічі.'),
    ('Samantha', 'I will update the calendar and send everyone the meeting notes.'),
    ('Lesya', 'Дякую. Я підготую схему та форму відгуків до кінця дня.'),
)


def generate(output: Path, reference_output: Path, say: str = '/usr/bin/say',
             ffmpeg: str = 'ffmpeg', words_per_minute: int = 220):
    if len({text for _, text in DIALOGUE}) != len(DIALOGUE):
        raise ValueError('conversation turns must all be unique')
    if not DIALOGUE or not all(voice in {'Samantha', 'Lesya'} for voice, _ in DIALOGUE):
        raise ValueError('conversation must use the configured local English/Ukrainian voices')

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='meeting-asr-dialogue-') as temporary:
        temporary_path = Path(temporary)
        utterances = []
        for index, (voice, text) in enumerate(DIALOGUE):
            aiff_path = temporary_path / f'turn-{index:02d}.aiff'
            wav_path = temporary_path / f'turn-{index:02d}.wav'
            subprocess.run([say, '-v', voice, '-r', str(words_per_minute),
                            '-o', str(aiff_path), text],
                           check=True, timeout=60)
            subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', str(aiff_path),
                            '-ar', str(SAMPLE_RATE), '-ac', '1', str(wav_path)],
                           check=True, timeout=30)
            with wave.open(str(wav_path), 'rb') as audio_file:
                if audio_file.getparams()[:3] != (1, 2, SAMPLE_RATE):
                    raise ValueError(f'{voice} voice did not produce mono PCM16 at {SAMPLE_RATE} Hz')
                utterances.append(audio_file.readframes(audio_file.getnframes()))

    target_samples = TARGET_SECONDS * SAMPLE_RATE
    speech_samples = sum(len(audio) // 2 for audio in utterances)
    gap_count = len(utterances) - 1
    minimum_gap_samples = round(TURN_GAP_SECONDS * SAMPLE_RATE)
    remaining_gap_samples = target_samples - speech_samples - gap_count * minimum_gap_samples
    if remaining_gap_samples < 0:
        raise ValueError('synthesized dialogue exceeds the three-minute target')
    per_gap, extra_gap = divmod(remaining_gap_samples, gap_count)
    silence = b'\x00\x00'
    audio = bytearray()
    for index, utterance in enumerate(utterances):
        audio.extend(utterance)
        if index < gap_count:
            gap_samples = minimum_gap_samples + per_gap + (index < extra_gap)
            audio.extend(silence * gap_samples)
    if len(audio) != target_samples * 2:
        raise RuntimeError('generated fixture did not reach exactly three minutes')

    with wave.open(str(output), 'wb') as target:
        target.setparams((1, 2, SAMPLE_RATE, target_samples, 'NONE', 'not compressed'))
        target.writeframes(audio)
    reference = ' '.join(text for _, text in DIALOGUE)
    reference_output.parent.mkdir(parents=True, exist_ok=True)
    reference_output.write_text(reference + '\n')
    return {
        'durationSeconds': TARGET_SECONDS,
        'sampleRate': SAMPLE_RATE,
        'turnCount': len(DIALOGUE),
        'uniqueTurnCount': len({text for _, text in DIALOGUE}),
        'voiceTurnCounts': {voice: sum(item_voice == voice for item_voice, _ in DIALOGUE)
                            for voice in ('Samantha', 'Lesya')},
        'speechDurationSeconds': speech_samples / SAMPLE_RATE,
        'averageTurnGapSeconds': (target_samples - speech_samples) / SAMPLE_RATE / gap_count,
        'sourceSha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'referenceText': reference,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reference-output', type=Path, required=True)
    parser.add_argument('--say', default='/usr/bin/say')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--words-per-minute', type=int, default=220)
    args = parser.parse_args()
    print(json.dumps(generate(args.output, args.reference_output, args.say, args.ffmpeg,
                              args.words_per_minute),
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
