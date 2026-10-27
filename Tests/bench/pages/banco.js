// Ogni pagina del Banco di prova scrive il proprio stato nel titolo della finestra:
// il comando --agent-bench lo legge con l'Accessibilità per verificare il compito.
function banco(nome, stato) {
  document.title = "Banco " + nome + " · " + stato.filter(Boolean).join(" · ");
}
