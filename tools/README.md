# tools/: integração das ferramentas de acesso (Meta 2)

Esta pasta vai receber o trabalho de unificar a criação de acessos dos alunos, hoje feita por duas ferramentas independentes:

| Pasta | Ferramenta atual | Papel |
|---|---|---|
| `ad_manager/` | Ferramenta Python de gerenciamento de usuários do Active Directory | Cria os acessos dos alunos no AD |
| `moodle/` | Ferramenta HTML que usa a API do Moodle | Cria o aluno e a matrícula no portal Moodle |

As duas são alimentadas hoje por planilha extraída do Sponte. O plano é que passem a ler do DW (veja a Meta 2 em `docs/ROADMAP.md`).

**Enquanto isso, nada aqui é obrigatório.** Quando for a hora, copie o código de cada ferramenta para a sua pasta, sem credenciais, e documente no README da pasta quais colunas ela consome.
