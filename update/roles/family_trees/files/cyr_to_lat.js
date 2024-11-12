async function loadDictionary() {
    const response = await fetch('dictionary.json');
    const dictionary = await response.json();
    return dictionary;
}

function cyrToLat(text) {
    const cyrillic = [
        'А', 'Б', 'В', 'Г', 'Д', 'Ђ', 'Е', 'Ж', 'З', 'И', 'Ј', 'К', 'Л', 'Љ', 'М', 'Н', 'Њ', 'О', 'П', 'Р', 'С', 'Т', 'Ћ', 'У', 'Ф', 'Х', 'Ц', 'Ч', 'Џ', 'Ш',
        'а', 'б', 'в', 'г', 'д', 'ђ', 'е', 'ж', 'з', 'и', 'ј', 'к', 'л', 'љ', 'м', 'н', 'њ', 'о', 'п', 'р', 'с', 'т', 'ћ', 'у', 'ф', 'х', 'ц', 'ч', 'џ', 'ш'
    ];
    const latin = [
        'A', 'B', 'V', 'G', 'D', 'Đ', 'E', 'Ž', 'Z', 'I', 'J', 'K', 'L', 'Lj', 'M', 'N', 'Nj', 'O', 'P', 'R', 'S', 'T', 'Ć', 'U', 'F', 'H', 'C', 'Č', 'Dž', 'Š',
        'a', 'b', 'v', 'g', 'd', 'đ', 'e', 'ž', 'z', 'i', 'j', 'k', 'l', 'lj', 'm', 'n', 'nj', 'o', 'p', 'r', 's', 't', 'ć', 'u', 'f', 'h', 'c', 'č', 'dž', 'š'
    ];

    let newText = text;
    for (let i = 0; i < cyrillic.length; i++) {
        newText = newText.split(cyrillic[i]).join(latin[i]);
    }
    return newText;
}

async function toggleCyrLat() {
    console.log('Usao');
    let convertedText = '';
    const dictionary = await loadDictionary();
    console.log(dictionary);
    const textElements = document.querySelectorAll('text'); // Using 'text' as the selector

    textElements.forEach(element => {
        const currentText = element.textContent.trim(); // Trim to avoid leading/trailing whitespace issues
        // Check if the text is in the dictionary
        if (dictionary.hasOwnProperty(currentText)) {
            convertedText = dictionary[currentText]; // Return the translated text
        } else {
            convertedText = cyrToLat(currentText);
        }  
        element.textContent = convertedText;
    });

    reset = reset + 1;
    if (reset > 1) {
        location.reload();
    }
}
