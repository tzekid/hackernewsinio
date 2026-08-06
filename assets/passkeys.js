(function () {
  "use strict";

  function supported() {
    return Boolean(window.isSecureContext && window.PublicKeyCredential && navigator.credentials);
  }

  function fromBase64url(value) {
    var base64 = String(value).replace(/-/g, "+").replace(/_/g, "/");
    var binary = window.atob(base64 + "=".repeat((4 - base64.length % 4) % 4));
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  function toBase64url(value) {
    var bytes = new Uint8Array(value);
    var binary = "";
    for (var i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function creationOptions(value) {
    var result = Object.assign({}, value, {
      challenge: fromBase64url(value.challenge),
      user: Object.assign({}, value.user, { id: fromBase64url(value.user.id) })
    });
    result.excludeCredentials = (value.excludeCredentials || []).map(function (item) {
      return Object.assign({}, item, { id: fromBase64url(item.id) });
    });
    return result;
  }

  function requestOptions(value) {
    var result = Object.assign({}, value, { challenge: fromBase64url(value.challenge) });
    result.allowCredentials = (value.allowCredentials || []).map(function (item) {
      return Object.assign({}, item, { id: fromBase64url(item.id) });
    });
    return result;
  }

  async function post(url, body) {
    var response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body || {})
    });
    var data = await response.json().catch(function () { return {}; });
    if (!response.ok) throw new Error(data.error || "The passkey request failed.");
    return data;
  }

  async function register(button) {
    var options = await post("/auth/register/options", {});
    var credential = await navigator.credentials.create({ publicKey: creationOptions(options.publicKey) });
    if (!credential) throw new Error("Passkey creation was cancelled.");
    var transports = typeof credential.response.getTransports === "function" ? credential.response.getTransports() : [];
    await post("/auth/register/finish", {
      challenge_id: options.challenge_id,
      credential_id: toBase64url(credential.rawId),
      client_data_json: toBase64url(credential.response.clientDataJSON),
      attestation_object: toBase64url(credential.response.attestationObject),
      transports: transports.join(","),
      label: "Personal passkey"
    });
    window.location.replace("/settings");
  }

  async function addPasskey() {
    var options = await post("/auth/passkeys/options", {});
    var credential = await navigator.credentials.create({ publicKey: creationOptions(options.publicKey) });
    if (!credential) throw new Error("Passkey creation was cancelled.");
    var transports = typeof credential.response.getTransports === "function" ? credential.response.getTransports() : [];
    await post("/auth/passkeys/finish", {
      challenge_id: options.challenge_id,
      credential_id: toBase64url(credential.rawId),
      client_data_json: toBase64url(credential.response.clientDataJSON),
      attestation_object: toBase64url(credential.response.attestationObject),
      transports: transports.join(","),
      label: "Additional passkey"
    });
    window.location.replace("/settings");
  }

  async function login() {
    var options = await post("/auth/login/options", {});
    var credential = await navigator.credentials.get({ publicKey: requestOptions(options.publicKey) });
    if (!credential) throw new Error("Passkey sign-in was cancelled.");
    await post("/auth/login/finish", {
      challenge_id: options.challenge_id,
      credential_id: toBase64url(credential.rawId),
      client_data_json: toBase64url(credential.response.clientDataJSON),
      authenticator_data: toBase64url(credential.response.authenticatorData),
      signature: toBase64url(credential.response.signature)
    });
    window.location.replace("/inbox");
  }

  function bind(selector, action) {
    var button = document.querySelector(selector);
    if (!button) return;
    if (!supported()) {
      button.disabled = true;
      button.insertAdjacentHTML("afterend", "<p class=\"status-banner\">Passkeys require a current browser and a secure connection.</p>");
      return;
    }
    button.addEventListener("click", async function () {
      button.disabled = true;
      var original = button.textContent;
      button.textContent = "Waiting for your device…";
      try { await action(button); }
      catch (failure) {
        var message = document.createElement("p");
        message.className = "status-banner";
        message.setAttribute("role", "alert");
        message.textContent = failure && failure.name === "NotAllowedError" ? "The passkey request was cancelled or timed out." : failure.message;
        button.insertAdjacentElement("afterend", message);
      } finally {
        button.disabled = false;
        button.textContent = original;
      }
    });
  }

  bind("[data-passkey-register]", register);
  bind("[data-passkey-login]", login);
  bind("[data-passkey-add]", addPasskey);
})();
