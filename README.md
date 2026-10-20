# Satturnex CRM

CRM privado para leads, propostas, projetos e tarefas, financeiro, custos recorrentes, mensagens e estimativas. A interface está em pt-BR; Supabase PostgreSQL é a fonte dos dados. A planilha encontrada no repositório foi lida: a importação contém os 20 leads da aba **CRM de Leads**. As abas de Painel, Mensagens, Acordo da dupla, Custos, Negociar, Calculadora e Finanças foram usadas como referência para módulos, modelos de mensagens, divisão indicativa, custos e cálculos. Nenhum lead ou lançamento foi inventado; as abas financeiras não tinham lançamentos preenchidos.

## Configuração local

Requisitos: Node.js 20+ e npm.

```bash
npm install
```

Copie `.env.example` para `.env.local` e configure:

```env
VITE_SUPABASE_URL=https://SEU-PROJETO.supabase.co
VITE_SUPABASE_ANON_KEY=SUA_CHAVE_PUBLICA_ANON
```

Use somente a URL e a chave pública anon/publishable. **Nunca use `service_role` no frontend.** Inicie com `npm run dev`; sem as duas variáveis, a aplicação mostra instruções de configuração sem tentar abrir sessão nem exibir tela branca.

## Criar banco e usuários pelo navegador

1. Crie/abra um projeto no Supabase.
2. Siga [supabase/sql/README.md](supabase/sql/README.md): cole os arquivos `supabase/sql/01_schema.sql` a `05_seed.sql` no SQL Editor do Dashboard, em ordem. Não precisa de Supabase CLI.
3. Desative o cadastro público e crie os acessos de Gustavo e Manel pelo Dashboard. Insira os dois UUIDs em `workspace_members` conforme o exemplo do README SQL. Sem essa associação, login não libera leitura de nenhum dado de CRM.
4. Copie a URL e a chave pública anon do projeto para `.env.local`.
5. Importe os leads reais pelo Table Editor seguindo [supabase/import/IMPORTAR_CSV.md](supabase/import/IMPORTAR_CSV.md). CSV: [leads_satturnex.csv](supabase/import/leads_satturnex.csv). Esse arquivo contém dados comerciais da planilha; mantenha-o apenas no repositório privado/projeto autorizado.

## Funcionalidades

- Login/logout Supabase Auth e proteção do workspace por associação validada no PostgreSQL/RLS.
- Dashboard com métricas carregadas do banco, funil, resultados realizados e próximos follow-ups.
- CRUD com pesquisa e confirmação de exclusão para leads, propostas, projetos, tarefas, transações, custos, modelos de mensagens e atividades.
- Leads com link WhatsApp formado a partir dos dígitos informados; confirme o DDI antes de abrir. Modelos de mensagens copiam com fallback quando Clipboard API não está disponível.
- Finanças usam `numeric(12,2)`; resultado realizado considera somente receitas recebidas e despesas pagas. 50/50 é referência informativa, não aconselhamento contábil/legal. Lançamentos são sempre registrados manualmente; aceitar proposta não cria receita automaticamente.
- Custos e calculadora com referências editáveis. A referência do projeto é R$ 159,00 a cada três anos; a planilha existente registra R$ 112,00 em um resumo financeiro antigo. O seed usa R$ 159,00 e deixa a divergência explícita para confirmação. A calculadora indica estimativas e não consulta preços automaticamente.

## Build e deploy Vercel

- Framework preset: **Vite**
- Build command: `npm run build`
- Output directory: `dist`
- Variáveis na Vercel: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`
- Cadastre URLs local e de produção em **Supabase → Authentication → URL Configuration → Redirect URLs**. Desative signups públicos.
- Após mudar variáveis na Vercel, faça um novo deploy/redeploy.

A configuração padrão da Vercel atende a SPA do Vite; não é necessário `vercel.json` para as rotas atuais.

## Solução de problemas

- **Tela pede configuração:** confira `.env.local` e reinicie `npm run dev`.
- **Login inválido:** confirme credenciais, usuário existente e confirmação de e-mail em Authentication → Users.
- **Login aceita, mas consulta dá erro/RLS:** confira a associação usuário/workspace em `workspace_members` e a execução dos cinco SQLs.
- **CSV recusado:** siga o mapeamento do guia de importação, preserve `workspace_id` e corrija duplicatas antes de repetir a carga.
- **Sessão expirada:** entre novamente. O Supabase renova tokens e a aplicação escuta mudanças de sessão.

## Verificação

Use `npm run build` para compilar TypeScript e gerar o bundle de produção. O build valida a compilação da interface, mas a conexão Supabase, RLS e autenticação precisam ser confirmadas no projeto Supabase que você configurar.
