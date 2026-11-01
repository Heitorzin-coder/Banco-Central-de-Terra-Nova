(() => {
  const cfg = window.BCTN_CONFIG || {};
  const $ = (id) => document.getElementById(id);
  const authView = $("auth-view"), bankView = $("bank-view");
  let supabaseClient;

  function message(id, text, isError=false) {
    const el = $(id); el.textContent = text;
    el.style.color = isError ? "#f0a18f" : "#d8c27e";
  }
  function money(value) {
    return new Intl.NumberFormat("pt-BR",{style:"currency",currency:"BRL"}).format(Number(value||0)).replace("R$","TN$");
  }
  function date(value) {
    return new Date(value).toLocaleString("pt-BR",{dateStyle:"short",timeStyle:"short"});
  }
  function showAuth() { authView.classList.remove("hidden"); bankView.classList.add("hidden"); }
  function showBank() { authView.classList.add("hidden"); bankView.classList.remove("hidden"); }

  $("show-login").addEventListener("click", () => {
    $("login-form").classList.remove("hidden"); $("signup-form").classList.add("hidden");
    $("show-login").classList.add("active"); $("show-signup").classList.remove("active");
  });
  $("show-signup").addEventListener("click", () => {
    $("signup-form").classList.remove("hidden"); $("login-form").classList.add("hidden");
    $("show-signup").classList.add("active"); $("show-login").classList.remove("active");
  });

  async function loadDashboard() {
    const {data:{user}} = await supabaseClient.auth.getUser();
    if (!user) return showAuth();
    const [{data:profile,error:pErr},{data:account,error:aErr}] = await Promise.all([
      supabaseClient.from("profiles").select("display_name").eq("user_id",user.id).single(),
      supabaseClient.from("accounts").select("id,pix_key,balance,currency").eq("owner_id",user.id).single()
    ]);
    if (pErr || aErr) throw new Error("Não foi possível carregar sua conta. Confira se o SQL foi executado.");
    $("display-name").textContent = profile.display_name;
    $("balance").textContent = money(account.balance);
    $("pix-key").textContent = account.pix_key;
    showBank();
    await loadHistory(account.id);
  }

  async function loadHistory(accountId) {
    const {data,error} = await supabaseClient.from("transfers")
      .select("id,sender_account_id,recipient_account_id,amount,description,created_at")
      .or(`sender_account_id.eq.${accountId},recipient_account_id.eq.${accountId}`)
      .order("created_at",{ascending:false}).limit(20);
    if (error) throw error;
    const host = $("history");
    if (!data.length) { host.innerHTML = '<p class="hint">Nenhuma movimentação ainda. Seu extrato aparecerá aqui.</p>'; return; }
    host.replaceChildren();
    data.forEach(row => {
      const incoming = row.recipient_account_id === accountId;
      const item = document.createElement("div"); item.className = "history-row";
      const info = document.createElement("div");
      const title = document.createElement("strong");
      title.textContent = incoming ? "Transferência recebida" : "Transferência enviada";
      const detail = document.createElement("small");
      detail.textContent = `${date(row.created_at)}${row.description ? " · "+row.description : ""}`;
      info.append(title,detail);
      const amount = document.createElement("strong");
      amount.className = incoming ? "incoming" : "outgoing";
      amount.textContent = `${incoming?"+":"−"} ${money(row.amount)}`;
      item.append(info,amount); host.append(item);
    });
  }

  $("login-form").addEventListener("submit", async (event) => {
    event.preventDefault(); message("auth-message","Entrando...");
    const {error} = await supabaseClient.auth.signInWithPassword({
      email:$("login-email").value.trim(),password:$("login-password").value
    });
    if (error) return message("auth-message",error.message,true);
    try { await loadDashboard(); } catch(e) { message("auth-message",e.message,true); }
  });

  $("signup-form").addEventListener("submit", async (event) => {
    event.preventDefault(); message("auth-message","Criando sua conta...");
    const {data,error} = await supabaseClient.auth.signUp({
      email:$("signup-email").value.trim(),password:$("signup-password").value,
      options:{data:{display_name:$("signup-name").value.trim()}}
    });
    if (error) return message("auth-message",error.message,true);
    if (!data.session) {
      message("auth-message","Cadastro iniciado! Confirme seu e-mail e depois entre na conta.");
      return;
    }
    try { await loadDashboard(); } catch(e) { message("auth-message",e.message,true); }
  });

  $("transfer-form").addEventListener("submit", async (event) => {
    event.preventDefault(); message("transfer-message","Processando transferência...");
    const amount = Number($("transfer-amount").value);
    if (!Number.isFinite(amount) || amount <= 0) return message("transfer-message","Digite um valor válido.",true);
    const {data,error} = await supabaseClient.rpc("bctn_transfer",{
      recipient_key:$("recipient-key").value.trim().toUpperCase(),
      transfer_amount:amount,
      transfer_description:$("transfer-description").value.trim()
    });
    if (error) return message("transfer-message",error.message,true);
    message("transfer-message",`Transferência concluída para ${data[0].recipient_name}!`);
    $("transfer-form").reset();
    await loadDashboard();
  });

  $("refresh").addEventListener("click", async () => {
    try { await loadDashboard(); } catch(e) { message("transfer-message",e.message,true); }
  });
  $("logout").addEventListener("click", async () => {
    await supabaseClient.auth.signOut(); showAuth();
  });

  async function start() {
    if (!cfg.supabaseUrl || cfg.supabaseUrl.includes("SEU-PROJETO") ||
        !cfg.supabaseAnonKey || cfg.supabaseAnonKey.includes("SUA_CHAVE")) {
      message("auth-message","Configure a URL e a chave anon/public no arquivo config.js para começar.",true);
      return;
    }
    supabaseClient = window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
    const {data:{session}} = await supabaseClient.auth.getSession();
    if (session) {
      try { await loadDashboard(); } catch(e) { message("auth-message",e.message,true); }
    }
    supabaseClient.auth.onAuthStateChange((_event,session) => {
      if (!session) showAuth();
    });
  }
  start();
})();
