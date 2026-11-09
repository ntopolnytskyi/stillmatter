"""Synthesize a three-minute clip with Ukrainian/English/Ukrainian minute blocks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import wave


SAMPLE_RATE = 16000
BLOCK_SECONDS = 60
TURN_GAP_SECONDS = 0.35
BLOCKS = (
    ('uk', 'Lesya', (
        'Почнімо з плану запуску. Нам потрібно перевірити строки, ризики та відповідальних за кожен етап.',
        'Найбільше мене турбує переклад інструкцій. Підрядник обіцяв готовий текст до середи.',
        'Я вже написала редакторці. Вона надішле першу частину сьогодні, а решту завтра вранці.',
        'Добре, попроси Андрія перевірити назви кнопок і кроки початкового налаштування.',
        'Він погодився. Я надішлю йому посилання та коротко поясню, як залишати коментарі.',
        'Ще треба вирішити, чи запрошуємо всіх клієнтів, чи спершу кілька команд.',
        'Пропоную почати з десяти команд. Так ми швидше помітимо помилки без зайвого ризику.',
        'Підтримку забезпечать двоє колег. Я також чергуватиму в робочому чаті в п’ятницю.',
        'Тоді до четверга підготуємо форму відгуків і короткий опис нового процесу.',
        'Так, а запрошення надішлемо після перевірки тексту та підтвердження графіка підтримки.',
    )),
    ('en', 'Samantha', (
        'For the first release, let us invite ten teams and review their feedback on Monday.',
        'That gives support a manageable group while we check setup problems and confusing instructions.',
        'I will ask two colleagues to cover the help channel throughout Friday afternoon.',
        'Please make sure the invitation explains that this is a limited preview, not the final launch.',
        'The feedback form should ask where people stopped and how long setup took.',
        'We can include an optional comment box, but keep the required questions short.',
        'I will update the calendar and send the draft agenda to everyone tomorrow morning.',
        'Could you also prepare one slide comparing the old workflow with the new one?',
        'Yes, and I will include a checklist with an owner and due date for every task.',
        'After the review, we can decide whether to invite twenty more teams next week.',
    )),
    ('uk', 'Lesya', (
        'Повернімося до перекладу. Андрій уже переглянув перші сторінки й залишив кілька корисних правок.',
        'Я прийму його пропозиції та перевірю, щоб назви кнопок збігалися з додатком.',
        'Редакторка підтвердила, що завершить решту інструкцій завтра до обіду.',
        'Чудово. Після цього перевіримо налаштування на новому обліковому записі.',
        'Для відгуків я додала питання про помилки, зрозумілість і витрачений час.',
        'Форма коротка, а поле для додаткових коментарів залишила необов’язковим.',
        'Я також склала список десяти команд із новими та досвідченими користувачами.',
        'Надішли мені список сьогодні. Я перевірю, чи всі підтвердили участь у п’ятницю.',
        'Якщо хтось відмовиться, запросимо іншу команду до початку тестового запуску.',
        'Домовились. У понеділок переглянемо відповіді та вирішимо, чи розширювати доступ.',
    )),
)


def generate(output: Path, reference_output: Path, say: str = '/usr/bin/say', ffmpeg: str = 'ffmpeg',
             words_per_minute: int = 220):
    flattened = [(language, voice, text) for language, voice, lines in BLOCKS
                 for text in lines]
    texts = [text for _, _, text in flattened]
    if len(set(texts)) != len(texts):
        raise ValueError('all conversation turns must be unique')

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='meeting-asr-uk-en-uk-') as temporary:
        temporary_path = Path(temporary)
        block_audio = []
        block_speech_seconds = []
        for block_index, (language, voice, lines) in enumerate(BLOCKS):
            utterances = []
            for turn_index, text in enumerate(lines):
                aiff_path = temporary_path / f'block-{block_index}-turn-{turn_index}.aiff'
                wav_path = temporary_path / f'block-{block_index}-turn-{turn_index}.wav'
                subprocess.run([say, '-v', voice, '-r', str(words_per_minute),
                                '-o', str(aiff_path), text], check=True, timeout=60)
                subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', str(aiff_path),
                                '-ar', str(SAMPLE_RATE), '-ac', '1', str(wav_path)],
                               check=True, timeout=30)
                with wave.open(str(wav_path), 'rb') as audio_file:
                    if audio_file.getparams()[:3] != (1, 2, SAMPLE_RATE):
                        raise ValueError(f'{voice} did not produce mono PCM16 at {SAMPLE_RATE} Hz')
                    utterances.append(audio_file.readframes(audio_file.getnframes()))

            target_samples = BLOCK_SECONDS * SAMPLE_RATE
            speech_samples = sum(len(audio) // 2 for audio in utterances)
            gap_count = len(utterances) - 1
            minimum_gap_samples = round(TURN_GAP_SECONDS * SAMPLE_RATE)
            remaining_gap_samples = target_samples - speech_samples - gap_count * minimum_gap_samples
            if remaining_gap_samples < 0:
                raise ValueError(f'{language} speech exceeds its one-minute block')
            per_gap, extra_gap = divmod(remaining_gap_samples, gap_count)
            audio = bytearray()
            for index, utterance in enumerate(utterances):
                audio.extend(utterance)
                if index < gap_count:
                    gap_samples = minimum_gap_samples + per_gap + (index < extra_gap)
                    audio.extend(b'\x00\x00' * gap_samples)
            if len(audio) != target_samples * 2:
                raise RuntimeError(f'{language} block did not reach exactly one minute')
            block_audio.append(audio)
            block_speech_seconds.append(speech_samples / SAMPLE_RATE)

    complete_audio = b''.join(block_audio)
    with wave.open(str(output), 'wb') as target:
        target.setparams((1, 2, SAMPLE_RATE, BLOCK_SECONDS * len(BLOCKS) * SAMPLE_RATE,
                          'NONE', 'not compressed'))
        target.writeframes(complete_audio)
    reference = ' '.join(text for _, _, text in flattened)
    reference_output.parent.mkdir(parents=True, exist_ok=True)
    reference_output.write_text(reference + '\n')
    return {
        'durationSeconds': BLOCK_SECONDS * len(BLOCKS),
        'sampleRate': SAMPLE_RATE,
        'languageBlockSeconds': BLOCK_SECONDS,
        'languagePattern': [language for language, _, _ in BLOCKS],
        'turnCounts': [len(lines) for _, _, lines in BLOCKS],
        'speechDurationSecondsByBlock': block_speech_seconds,
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
                              args.words_per_minute), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
