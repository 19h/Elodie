//! Cleans up what was said before it's stored.

/// Who said something.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Speaker {
    /// The microphone.
    Me,
    /// The computer's audio.
    Others,
}

/// A transcribed word.
#[derive(Clone, Debug, PartialEq)]
pub struct Word {
    pub text: String,
    pub t_ms: i64,
    pub duration_ms: i64,
    pub confidence: f32,
    pub speaker: Speaker,
}

/// How far apart a word and its echo can be.
const ECHO_WINDOW_MS: i64 = 1200;

fn normalized(word: &str) -> String {
    word.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Removes words the microphone only picked up from the speakers.
///
/// With speakers on, the microphone hears the meeting too, so the same words get
/// transcribed twice. The reference app muted the microphone whenever the speakers were
/// loud, which also lost anything you said over someone else. This keeps both tracks,
/// and drops a microphone word only when the same word came from the speakers around
/// the same moment. Your own speech survives unless you say the same word at that moment.
pub fn remove_echo(words: Vec<Word>) -> Vec<Word> {
    let others: Vec<(String, i64)> = words
        .iter()
        .filter(|word| word.speaker == Speaker::Others)
        .map(|word| (normalized(&word.text), word.t_ms))
        .collect();

    words
        .into_iter()
        .filter(|word| {
            if word.speaker == Speaker::Others {
                return true;
            }
            let text = normalized(&word.text);
            // Words that are only punctuation can't be judged as echoes.
            text.is_empty()
                || !others
                    .iter()
                    .any(|(other, t)| *other == text && (word.t_ms - t).abs() <= ECHO_WINDOW_MS)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str, t_ms: i64, speaker: Speaker) -> Word {
        Word { text: text.to_owned(), t_ms, duration_ms: 200, confidence: 0.9, speaker }
    }

    fn texts(words: &[Word]) -> Vec<&str> {
        words.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn an_echoed_word_is_dropped_from_the_microphone() {
        let kept = remove_echo(vec![
            word("budget", 1000, Speaker::Others),
            word("budget", 1100, Speaker::Me),
        ]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].speaker, Speaker::Others);
    }

    /// This is what the reference app's mute got wrong.
    #[test]
    fn speaking_over_someone_else_keeps_your_words() {
        let kept = remove_echo(vec![
            word("budget", 1000, Speaker::Others),
            word("wait", 1050, Speaker::Me),
            word("stop", 1250, Speaker::Me),
        ]);
        assert_eq!(texts(&kept), ["budget", "wait", "stop"]);
    }

    #[test]
    fn the_same_word_later_is_not_an_echo() {
        let kept = remove_echo(vec![
            word("budget", 1000, Speaker::Others),
            word("budget", 5000, Speaker::Me),
        ]);
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn case_and_punctuation_do_not_hide_an_echo() {
        let kept = remove_echo(vec![
            word("Budget,", 1000, Speaker::Others),
            word("budget", 1100, Speaker::Me),
        ]);
        assert_eq!(kept.len(), 1);
    }

    #[test]
    fn words_from_the_speakers_are_always_kept() {
        let kept = remove_echo(vec![
            word("one", 1000, Speaker::Others),
            word("one", 1000, Speaker::Others),
        ]);
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn with_no_speaker_audio_everything_stays() {
        let kept = remove_echo(vec![word("hello", 1000, Speaker::Me), word("there", 1300, Speaker::Me)]);
        assert_eq!(texts(&kept), ["hello", "there"]);
    }
}
