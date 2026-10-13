package br.com.trabalho.vendas;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ConfigController {

    @Value("${mensagem.boasvindas:Configuração não carregada}")
    private String mensagem;

    @GetMapping("/mensagem")
    public String mensagem() {
        return this.mensagem;
    }
}
